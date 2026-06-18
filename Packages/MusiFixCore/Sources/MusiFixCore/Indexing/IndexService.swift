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
        case resolvingLocations(resolved: Int, total: Int)
        case rebuildingFTS
        case done
        case failed(String)
    }
}

/// Actor che serializza l'accesso all'indice e a Music.app.
/// La UI osserva `progress` tramite AsyncStream.
public actor IndexService {

    private let db: AppDatabase
    // Non più usato per il fetch bulk (vedi bulkFetcher sotto); mantenuto per
    // coerenza dell'API pubblica e per eventuali letture/scritture puntuali
    // future (refresh di un singolo track, ecc.).
    private let bridge: any AppleMusicBridge
    // Fetch bulk sempre via AppleScript, indipendentemente dal bridge attivo:
    // ScriptingBridge fa un Apple Event per proprietà per ogni track (~20 ×
    // 25k brani = 500k+ eventi), e la risoluzione di `location` su un volume
    // esterno può incappare in lookup di catalogo lenti/falliti (vedi
    // FileIDTreeGetAndLockVolumeEntryFromIndex / -35 in Console). Lo script
    // AppleScript a blocchi fa un solo Apple Event per blocco e isola gli
    // alias irrisolvibili nel `try` per-track (vedi NSAppleScriptImpl).
    private let bulkFetcher = NSAppleScriptImpl()
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

        // 1. Conta i brani
        log.info("[trace] Inizio trackCount()")
        let t0 = Date()
        let total = try await bulkFetcher.trackCount()
        log.info("[trace] trackCount() completato in \(Date().timeIntervalSince(t0), privacy: .public)s → \(total) brani")
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: total, lastSyncDate: nil))

        // 2. Leggi checkpoint per eventuale ripresa
        let resumeFrom = try loadCheckpointPID()
        log.info("[trace] Checkpoint: \(resumeFrom ?? "nessuno", privacy: .public)")
        var skipUntilPID = resumeFrom
        var processed = 0

        let chunkSize = 1000
        let batchSize = 500
        var batch: [DBTrack] = []
        batch.reserveCapacity(batchSize)

        var chunkStart = 1
        while chunkStart <= total {
            try Task.checkCancellation()

            let chunkEnd = min(chunkStart + chunkSize - 1, total)
            log.info("[trace] tracksChunk(\(chunkStart)-\(chunkEnd)) avvio")
            let tc0 = Date()
            let chunk = try await bulkFetcher.tracksChunk(from: chunkStart, to: chunkEnd)
            let elapsed = Date().timeIntervalSince(tc0)
            log.info("[trace] tracksChunk(\(chunkStart)-\(chunkEnd)) → \(chunk.count) track in \(String(format: "%.1f", elapsed))s")
            chunkStart = chunkEnd + 1

            if chunk.isEmpty {
                log.warning("[trace] Chunk vuoto! Script AppleScript restituisce stringa vuota o parsing fallito.")
            }

            for track in chunk {
                if let skip = skipUntilPID {
                    if track.persistentID != skip { continue }
                    skipUntilPID = nil
                }

                try Task.checkCancellation()
                let dbTrack = await buildDBTrack(from: track)
                batch.append(dbTrack)
                processed += 1

                if batch.count >= batchSize {
                    log.info("[trace] Salvataggio batch \(processed - batchSize + 1)-\(processed)")
                    try saveAndCheckpoint(batch: batch, lastPID: batch.last!.persistentID,
                                          processed: processed, total: total)
                    batch.removeAll(keepingCapacity: true)
                }
            }

            setProgress(.init(
                phase: .enrichingFiles(completed: processed, total: total),
                processed: processed, total: total, lastSyncDate: nil
            ))
        }

        // Ultimo batch
        if !batch.isEmpty {
            try saveAndCheckpoint(batch: batch, lastPID: batch.last!.persistentID,
                                  processed: processed, total: total)
        }

        // 4. Risolvi path via filesystem scan (evita la risoluzione alias HFS+ lenta)
        if let mediaFolder = Self.musicMediaFolderURL() {
            try await resolveLocations(mediaFolder: mediaFolder, total: processed)
        }

        // 5. FTS rebuild (se necessario dopo upsert massivo senza trigger)
        try rebuildFTSIfNeeded()

        // 6. Marca sync completata
        try db.write { db in
            try SyncStateDAO.setLastMusicSync(Date(), in: db)
            try db.execute(sql: "DELETE FROM indexing_checkpoint")
        }

        let syncDate = Date()
        log.info("Indicizzazione completa: \(processed) brani")
        setProgress(.init(phase: .done, processed: processed, total: total, lastSyncDate: syncDate))
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

        // Tutti i track da Music, a blocchi (vedi nota su bulkFetcher in
        // runFullIndex: evita 20+ Apple Event per track via ScriptingBridge
        // e dà progresso/cancellazione reali tra un blocco e il successivo).
        let total = try await bulkFetcher.trackCount()
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: total, lastSyncDate: nil))

        var musicTracks: [Track] = []
        musicTracks.reserveCapacity(total)
        let chunkSize = 1000
        var chunkStart = 1
        while chunkStart <= total {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + chunkSize - 1, total)
            musicTracks.append(contentsOf: try await bulkFetcher.tracksChunk(from: chunkStart, to: chunkEnd))
            chunkStart = chunkEnd + 1
            setProgress(.init(phase: .fetchingFromMusic, processed: musicTracks.count, total: total, lastSyncDate: nil))
        }

        var updated = 0
        var added = 0
        var removed = 0

        // Track nuovi o modificati
        var toUpsert: [DBTrack] = []
        let musicPIDs = Set(musicTracks.map { $0.persistentID })

        for track in musicTracks {
            try Task.checkCancellation()
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

    // ── Risoluzione path via filesystem (evita alias HFS+) ────────────────────

    /// Legge la cartella media di Music.app dalle preferenze utente.
    /// La chiave `media-folder-url` contiene il file:// URL impostato in
    /// Music → Preferenze → File → "Posizione cartella iTunes Media".
    static func musicMediaFolderURL() -> URL? {
        guard let raw = UserDefaults(suiteName: "com.apple.Music")?
                .string(forKey: "media-folder-url"),
              let url = URL(string: raw) else { return nil }
        // La cartella media di Music.app è [mediaRoot]/Music/
        return url.appendingPathComponent("Music", isDirectory: true)
    }

    /// Popola `locationPath`, `locationMtime`, `locationSize`, `contentHash` e
    /// `format` per i brani locali scansionando il filesystem della cartella media.
    /// Evita la risoluzione degli alias HFS+ via AppleScript che può bloccarsi su
    /// volumi con catalogo inconsistente (FileIDTreeGetAndLockVolumeEntryFromIndex -35).
    ///
    /// L'algoritmo costruisce un indice `(artist_folder, album_folder, trackNum) → path`
    /// dalla struttura di cartelle di Music.app (`Artist/Album/NN Title.ext`).
    func resolveLocations(mediaFolder: URL, total: Int) async throws {
        log.info("Risoluzione path via filesystem: \(mediaFolder.path)")
        setProgress(.init(phase: .resolvingLocations(resolved: 0, total: total),
                          processed: 0, total: total, lastSyncDate: nil))

        let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "aiff", "aif", "wav", "alac", "ogg", "opus", "wma"]

        // Scansione filesystem in Task.detached: DirectoryEnumerator non è Sendable
        // in contesti async. Costruisce indice (artist_folder, album_folder, trackNum) → path.
        let mediaFolderPath = mediaFolder.path
        let fileIndex: [String: String] = await Task.detached(priority: .userInitiated) {
            var idx: [String: String] = [:]
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: mediaFolderPath),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return idx }
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let filename = fileURL.deletingPathExtension().lastPathComponent
                let trackNum = IndexService.parseLeadingTrackNumber(from: filename)
                let albumFolder = fileURL.deletingLastPathComponent().lastPathComponent
                let artistFolder = fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let key = IndexService.locationKey(artist: artistFolder, album: albumFolder, trackNum: trackNum)
                if idx[key] == nil { idx[key] = fileURL.path }
            }
            return idx
        }.value
        log.info("File audio trovati nell'indice: \(fileIndex.count)")

        // Carica dal DB i brani senza path. Include anche quelli marcati isCloudOnly=1
        // da una sync precedente: il flag potrebbe essere stale (es. brano abbinato/
        // caricato che è stato poi scaricato localmente). Il filesystem è la fonte di
        // verità: se il file c'è → locale; se non c'è → cloud-only.
        struct TrackRow: Sendable {
            let pid: String; let artist: String; let albumArtist: String
            let album: String; let trackNum: Int
        }
        let tracksToResolve: [TrackRow] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, artist, albumArtist, album, trackNumber
                FROM track WHERE locationPath IS NULL
                """)
                .map { TrackRow(pid: $0["persistentID"] ?? "",
                                artist: $0["artist"] ?? "",
                                albumArtist: $0["albumArtist"] ?? "",
                                album: $0["album"] ?? "",
                                trackNum: $0["trackNumber"] ?? 0) }
        }

        var updates: [(pid: String, path: String)] = []
        for t in tracksToResolve {
            // Music.app usa albumArtist come cartella artista per le compilation
            let folderArtist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
            if let path = fileIndex[Self.locationKey(artist: folderArtist, album: t.album, trackNum: t.trackNum)] {
                updates.append((t.pid, path)); continue
            }
            if let path = fileIndex[Self.locationKey(artist: t.artist, album: t.album, trackNum: t.trackNum)] {
                updates.append((t.pid, path))
            }
        }
        log.info("Path risolti via filesystem: \(updates.count)/\(tracksToResolve.count)")

        // Brani non trovati dall'euristica filesystem. L'euristica fallisce su
        // strutture che non seguono Artist/Album/NN: compilation (cartella
        // Compilations), nomi sanitizzati da Music (es. "...Adriano" → "_..Adriano",
        // apostrofi curvi), prefissi disco nei filename ("1-08"), trackNumber=0.
        // Per questi chiediamo a Music.app la location reale: è la sola fonte di
        // verità affidabile. Solo i brani per cui Music NON restituisce un file
        // locale sono davvero cloud-only.
        var resolvedPIDs = Set(updates.map(\.pid))
        let heuristicUnresolved = tracksToResolve.map(\.pid).filter { !resolvedPIDs.contains($0) }

        if !heuristicUnresolved.isEmpty {
            log.info("Recovery location da Music per \(heuristicUnresolved.count) brani non risolti dall'euristica")
            let musicPaths = (try? await bulkFetcher.locationsForPersistentIDs(Set(heuristicUnresolved))) ?? [:]
            log.info("Location recuperate da Music: \(musicPaths.count)/\(heuristicUnresolved.count)")
            for (pid, path) in musicPaths where FileManager.default.fileExists(atPath: path) {
                updates.append((pid, path))
                resolvedPIDs.insert(pid)
            }
        }

        // Quel che resta senza path è cloud-only reale.
        let unresolvedPIDs = tracksToResolve.map(\.pid).filter { !resolvedPIDs.contains($0) }
        if !unresolvedPIDs.isEmpty {
            let placeholders = unresolvedPIDs.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(unresolvedPIDs.map { DatabaseValue(value: $0) })
            try db.write { db in
                try db.execute(
                    sql: "UPDATE track SET isCloudOnly=1, isEditable=0 WHERE persistentID IN (\(placeholders))",
                    arguments: args
                )
            }
            log.info("Brani marcati cloud-only (nessun file locale noto a Music): \(unresolvedPIDs.count)")
        }

        let updatesSnapshot = updates
        try db.write { db in
            for (pid, path) in updatesSnapshot {
                let ext = (path as NSString).pathExtension.lowercased()
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
                let size = (attrs?[.size] as? Int64) ?? (attrs?[.size] as? NSNumber)?.int64Value
                try db.execute(
                    sql: """
                        UPDATE track SET locationPath=?, format=?, locationMtime=?,
                        locationSize=?, isCloudOnly=0, isEditable=1 WHERE persistentID=?
                        """,
                    arguments: [path, ext, mtime, size, pid]
                )
            }
        }

        // Hash parziale in background, non blocca il completamento dell'indice
        Task.detached(priority: .utility) { [updates] in
            for (pid, path) in updates {
                guard let hash = await self.computePartialHash(path: path) else { continue }
                try? self.db.write { db in
                    try db.execute(sql: "UPDATE track SET contentHash=? WHERE persistentID=?",
                                   arguments: [hash, pid])
                }
            }
        }

        setProgress(.init(phase: .resolvingLocations(resolved: updates.count, total: tracksToResolve.count),
                          processed: updates.count, total: tracksToResolve.count, lastSyncDate: nil))
    }

    // ── Scansione presenza copertina (hasArtwork) ─────────────────────────────

    /// Verifica in Music.app se ogni brano ha almeno una copertina e aggiorna
    /// la colonna `hasArtwork` nel DB (0 = no, 1 = sì). Operazione on-demand:
    /// non parte automaticamente durante il sync per evitare ~2 Apple Events/brano
    /// sull'intera libreria; va avviata una volta sola dal pulsante "Scansiona
    /// copertine" e poi ri-eseguita solo dopo importazioni massicce.
    @discardableResult
    public func scanArtworkPresence() async throws -> Int {
        let total = try await bulkFetcher.trackCount()
        log.info("Scansione copertine avviata: \(total) brani")
        setProgress(.init(phase: .enrichingFiles(completed: 0, total: total),
                          processed: 0, total: total, lastSyncDate: nil))

        let chunkSize = 200
        var start = 1
        var scanned = 0

        while start <= total {
            try Task.checkCancellation()
            let end = min(start + chunkSize - 1, total)
            let (having, lacking) = try await bulkFetcher.artworkPresenceScan(from: start, to: end)

            let h = Array(having)
            let l = Array(lacking)
            try db.write { db in
                if !h.isEmpty {
                    let ph = h.map { _ in "?" }.joined(separator: ",")
                    try db.execute(sql: "UPDATE track SET hasArtwork=1 WHERE persistentID IN (\(ph))",
                                   arguments: StatementArguments(h.map { DatabaseValue(value: $0) }))
                }
                if !l.isEmpty {
                    let pl = l.map { _ in "?" }.joined(separator: ",")
                    try db.execute(sql: "UPDATE track SET hasArtwork=0 WHERE persistentID IN (\(pl))",
                                   arguments: StatementArguments(l.map { DatabaseValue(value: $0) }))
                }
            }
            scanned += h.count + l.count
            start = end + 1
            setProgress(.init(phase: .enrichingFiles(completed: scanned, total: total),
                              processed: scanned, total: total, lastSyncDate: nil))
        }

        log.info("Scansione copertine completata: \(scanned) brani")
        setProgress(.init(phase: .done, processed: scanned, total: total, lastSyncDate: nil))
        return scanned
    }

    // ── Riparazione mirata brani marcati cloud-only ───────────────────────────

    /// Recupera la location reale da Music.app per i brani attualmente marcati
    /// `isCloudOnly` (file non trovato dall'euristica filesystem). Più veloce di
    /// un re-index completo: non rifà il fetch dei 25k brani, agisce solo sul
    /// sottoinsieme cloud-only. I brani per cui Music restituisce un file locale
    /// esistente tornano editabili; gli altri restano cloud-only (cloud reali).
    @discardableResult
    public func repairCloudOnlyLocations() async throws -> Int {
        let cloudPIDs: [String] = try db.read { db in
            try String.fetchAll(db, sql: "SELECT persistentID FROM track WHERE isCloudOnly=1")
        }
        log.info("Riparazione cloud-only: \(cloudPIDs.count) candidati")
        guard !cloudPIDs.isEmpty else {
            setProgress(.init(phase: .done, processed: 0, total: 0, lastSyncDate: nil))
            return 0
        }
        setProgress(.init(phase: .resolvingLocations(resolved: 0, total: cloudPIDs.count),
                          processed: 0, total: cloudPIDs.count, lastSyncDate: nil))

        let musicPaths = try await bulkFetcher.locationsForPersistentIDs(Set(cloudPIDs))
        log.info("Location recuperate da Music: \(musicPaths.count)/\(cloudPIDs.count)")

        var repaired: [(pid: String, path: String)] = []
        for (pid, path) in musicPaths where FileManager.default.fileExists(atPath: path) {
            repaired.append((pid, path))
        }

        let snapshot = repaired
        try db.write { db in
            for (pid, path) in snapshot {
                let ext = (path as NSString).pathExtension.lowercased()
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
                let size = (attrs?[.size] as? Int64) ?? (attrs?[.size] as? NSNumber)?.int64Value
                try db.execute(
                    sql: """
                        UPDATE track SET locationPath=?, format=?, locationMtime=?,
                        locationSize=?, isCloudOnly=0, isEditable=1 WHERE persistentID=?
                        """,
                    arguments: [path, ext, mtime, size, pid]
                )
            }
        }
        log.info("Brani riparati (ora editabili): \(repaired.count)")

        // Hash parziale in background per i brani riparati
        Task.detached(priority: .utility) { [repaired] in
            for (pid, path) in repaired {
                guard let hash = await self.computePartialHash(path: path) else { continue }
                try? self.db.write { db in
                    try db.execute(sql: "UPDATE track SET contentHash=? WHERE persistentID=?",
                                   arguments: [hash, pid])
                }
            }
        }

        setProgress(.init(phase: .done, processed: repaired.count, total: cloudPIDs.count, lastSyncDate: nil))
        return repaired.count
    }

    /// Estrae il numero di traccia dal prefisso numerico del nome file.
    /// Es.: "01 One More Time" → 1, "12 Harder Better" → 12, "Intro" → 0
    private static func parseLeadingTrackNumber(from filename: String) -> Int {
        var digits = ""
        for ch in filename {
            if ch.isNumber { digits.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" || ch == "." { break }
            else { break }
        }
        return Int(digits) ?? 0
    }

    /// Chiave normalizzata per l'indice filesystem: lowercase + trim degli spazi.
    private static func locationKey(artist: String, album: String, trackNum: Int) -> String {
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
        let b = album.lowercased().trimmingCharacters(in: .whitespaces)
        return "\(a)\t\(b)\t\(trackNum)"
    }

    // ── Helpers privati ───────────────────────────────────────────────────────

    private func buildDBTrack(from track: Track) async -> DBTrack {
        let locationPath: String? = track.location?.path
        var mtime: Double? = nil
        var size: Int64? = nil
        var hash: String? = nil
        var format = ""

        // Se il location non è disponibile dal fetch (non richiesto nel bulk per
        // evitare la risoluzione alias HFS+ lenta), stima isCloudOnly dallo stato
        // iCloud reale (cloudStatus): le tracce ospitate in iCloud
        // (abbinate/caricate/acquistate/abbonamento) sono cloud; le altre sono
        // locali e avranno il path popolato da resolveLocations().
        let isCloudOnly: Bool
        if track.location != nil {
            isCloudOnly = false
        } else {
            isCloudOnly = CloudStatus(code: track.cloudStatus).isCloudHosted
        }

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
            cloudStatus: track.cloudStatus,
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

