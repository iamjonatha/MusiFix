import Foundation
import Persistence
import GRDB
import OSLog
import CommonCrypto

private let log = Logger(subsystem: "it.musifixapp", category: "IndexService")

/// Stato dell'indicizzazione, osservabile dall'UI.
public struct IndexProgress: Sendable {
    public var phase: Phase
    public var processed: Int
    public var total: Int
    public var lastSyncDate: Date?

    public init(phase: Phase, processed: Int, total: Int, lastSyncDate: Date?) {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.lastSyncDate = lastSyncDate
    }

    public enum Phase: Sendable {
        case idle
        case fetchingFromMusic
        case enrichingFiles(completed: Int, total: Int)
        case rebuildingFTS
        case done
        case failed(String)
    }
}

/// Actor che serializza l'accesso all'indice e a Music.app.
/// La UI osserva `progress` tramite AsyncStream.
public actor IndexService {

    private let db: AppDatabase
    private let bridge: any AppleMusicBridge
    private var progressContinuation: AsyncStream<IndexProgress>.Continuation?

    public private(set) var progress: IndexProgress = .init(
        phase: .idle, processed: 0, total: 0, lastSyncDate: nil
    )

    public init(db: AppDatabase, bridge: any AppleMusicBridge) {
        self.db = db
        self.bridge = bridge
    }

    public func progressStream() -> AsyncStream<IndexProgress> {
        AsyncStream { continuation in
            self.progressContinuation = continuation
            continuation.yield(self.progress)
        }
    }

    // ── Indicizzazione completa (F1.2) ────────────────────────────────────────

    /// Prima esecuzione o rebuild completo.
    /// Riprende da un checkpoint se l'esecuzione precedente fu interrotta.
    public func runFullIndex() async throws {
        log.info("Avvio indicizzazione completa")
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: 0, lastSyncDate: nil))

        // 1. Recupera tutti i track da Music.app
        let musicTracks = try await bridge.allTracks()
        log.info("Music.app: \(musicTracks.count) brani")
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: musicTracks.count, lastSyncDate: nil))

        // 2. Leggi checkpoint per eventuale ripresa
        let resumeFrom = try loadCheckpointPID()
        var skipUntilPID = resumeFrom
        var processed = 0

        // 3. Converti + salva a batch (evita transazioni enormi)
        let batchSize = 500
        var batch: [DBTrack] = []
        batch.reserveCapacity(batchSize)

        for track in musicTracks {
            // Ripresa: salta i brani già processati
            if let skip = skipUntilPID {
                if track.persistentID != skip { continue }
                skipUntilPID = nil  // trovato il checkpoint, riprendi da qui
            }

            let dbTrack = await buildDBTrack(from: track)
            batch.append(dbTrack)
            processed += 1

            if batch.count >= batchSize {
                try saveAndCheckpoint(batch: batch, lastPID: batch.last!.persistentID,
                                      processed: processed, total: musicTracks.count)
                batch.removeAll(keepingCapacity: true)
                setProgress(.init(
                    phase: .enrichingFiles(completed: processed, total: musicTracks.count),
                    processed: processed, total: musicTracks.count, lastSyncDate: nil
                ))
            }
        }

        // Ultimo batch
        if !batch.isEmpty {
            try saveAndCheckpoint(batch: batch, lastPID: batch.last!.persistentID,
                                  processed: processed, total: musicTracks.count)
        }

        // 4. FTS rebuild (se necessario dopo upsert massivo senza trigger)
        try rebuildFTSIfNeeded()

        // 5. Marca sync completata
        try db.write { db in
            try SyncStateDAO.setLastMusicSync(Date(), in: db)
            try db.execute(sql: "DELETE FROM indexing_checkpoint")
        }

        let syncDate = Date()
        log.info("Indicizzazione completa: \(processed) brani in \(String(format: "%.1f", 0.0))s")
        setProgress(.init(phase: .done, processed: processed, total: musicTracks.count, lastSyncDate: syncDate))
    }

    // ── Sync incrementale (F1.3) ──────────────────────────────────────────────

    /// Sincronizzazione veloce: confronta modDate e applica solo il delta.
    public func runIncrementalSync() async throws {
        log.info("Avvio sync incrementale")
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: 0, lastSyncDate: nil))

        // Snapshot delle modDate note nell'indice
        let knownModDates = try db.read { db in
            try TrackDAO.fetchModDates(in: db)
        }

        // Tutti i track da Music (solo proprietà leggere, poi filtriamo)
        let musicTracks = try await bridge.allTracks()

        var updated = 0
        var added = 0
        var removed = 0

        // Track nuovi o modificati
        var toUpsert: [DBTrack] = []
        let musicPIDs = Set(musicTracks.map { $0.persistentID })

        for track in musicTracks {
            let knownModDate = knownModDates[track.persistentID]
            if knownModDate == nil {
                // Nuovo
                toUpsert.append(await buildDBTrack(from: track))
                added += 1
            } else if let musicMod = track.modificationDate,
                      let known = knownModDate ?? nil,
                      musicMod > known {
                // Modificato
                toUpsert.append(await buildDBTrack(from: track))
                updated += 1
            }
        }

        // Track rimossi da Music
        let removedPIDs = Set(knownModDates.keys).subtracting(musicPIDs)
        removed = removedPIDs.count

        // Applica delta — snapshot locale per Sendable closure
        let upsertSnapshot = toUpsert
        let removedSnapshot = removedPIDs
        if !upsertSnapshot.isEmpty || !removedSnapshot.isEmpty {
            try db.write { db in
                for track in upsertSnapshot {
                    try TrackDAO.upsert(track, in: db)
                }
                for pid in removedSnapshot {
                    try TrackDAO.delete(persistentID: pid, in: db)
                }
                try SyncStateDAO.setLastMusicSync(Date(), in: db)
            }
        }

        let syncDate = Date()
        log.info("Sync incrementale: +\(added) ~\(updated) -\(removed)")
        setProgress(.init(
            phase: .done,
            processed: added + updated + removed,
            total: musicTracks.count,
            lastSyncDate: syncDate
        ))
    }

    // ── Helpers privati ───────────────────────────────────────────────────────

    private func buildDBTrack(from track: Track) async -> DBTrack {
        let locationPath: String? = track.location?.path
        var mtime: Double? = nil
        var size: Int64? = nil
        var hash: String? = nil
        var format = ""
        let isCloudOnly = locationPath == nil

        // Arricchimento file locale (F1.2): mtime, size, format, hash parziale
        if let path = locationPath {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: path))
            mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
            size = (attrs?[.size] as? Int64)
                ?? ((attrs?[.size] as? NSNumber)?.int64Value)
            format = (path as NSString).pathExtension.lowercased()
            hash = await computePartialHash(path: path)
        }

        return DBTrack(
            persistentID: track.persistentID,
            databaseID: track.databaseID,
            locationPath: locationPath,
            locationMtime: mtime,
            locationSize: size,
            contentHash: hash,
            isCloudOnly: isCloudOnly,
            isEditable: !isCloudOnly,
            name: track.name,
            artist: track.artist,
            albumArtist: track.albumArtist,
            album: track.album,
            year: track.year,
            genre: track.genre,
            comment: track.comment,
            composer: track.composer,
            trackNumber: track.trackNumber,
            trackCount: track.trackCount,
            discNumber: track.discNumber,
            discCount: track.discCount,
            duration: track.duration,
            bitRate: track.bitRate,
            sampleRate: track.sampleRate,
            format: format,
            kind: track.kind,
            musicDateAdded: track.dateAdded,
            musicModDate: track.modificationDate,
            indexedAt: Date()
        )
    }

    /// Hash SHA256 dei primi 64 KB del file — sufficiente per deduplicazione.
    private func computePartialHash(path: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? fh.close() }
            let data = (try? fh.read(upToCount: 65_536)) ?? Data()
            guard !data.isEmpty else { return nil }
            var digest = [UInt8](repeating: 0, count: 32)
            data.withUnsafeBytes { buf in
                _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &digest)
            }
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func saveAndCheckpoint(
        batch: [DBTrack],
        lastPID: String,
        processed: Int,
        total: Int
    ) throws {
        try db.write { db in
            try TrackDAO.upsertMany(batch, in: db)
            // Checkpoint: mantieni solo l'ultimo
            try db.execute(sql: "DELETE FROM indexing_checkpoint WHERE completedAt IS NULL")
            try db.execute(
                sql: """
                    INSERT INTO indexing_checkpoint
                        (startedAt, lastPersistentID, totalExpected, processed, phase)
                    VALUES (datetime('now'), ?, ?, ?, 'file_enrich')
                    """,
                arguments: [lastPID, total, processed]
            )
        }
    }

    private func loadCheckpointPID() throws -> String? {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT lastPersistentID FROM indexing_checkpoint
                WHERE completedAt IS NULL
                ORDER BY id DESC LIMIT 1
                """)
            return row?["lastPersistentID"]
        }
    }

    private func clearCheckpoint(in db: Database) throws {
        try db.execute(sql: "DELETE FROM indexing_checkpoint")
    }

    private func rebuildFTSIfNeeded() throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO track_fts(track_fts) VALUES('rebuild')")
        }
    }

    private func setProgress(_ p: IndexProgress) {
        progress = p
        progressContinuation?.yield(p)
    }
}

