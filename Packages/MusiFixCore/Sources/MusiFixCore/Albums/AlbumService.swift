import Foundation
import Persistence
import GRDB
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "AlbumService")

/// Actor che gestisce le operazioni a livello di album:
/// normalizzazione "- Single", report completezza, scrittura conteggi.
/// (Fase A: normalizzazione "- Single". Le fasi successive estendono questo actor.)
public actor AlbumService {

    private let db: AppDatabase
    private let writeService: MetadataWriteService
    private let enrichment: EnrichmentService

    public init(db: AppDatabase, writeService: MetadataWriteService, enrichment: EnrichmentService) {
        self.db = db
        self.writeService = writeService
        self.enrichment = enrichment
    }

    /// Suffisso convenzionale Apple per i singoli.
    public static let singleSuffix = " - Single"

    // ── Fase B/G: aggregazione album ────────────────────────────────────────────

    /// Tutti gli album (esclusi singoli e album vuoti), ordinati per artista+album.
    public func albumGroups() throws -> [AlbumGroup] {
        try db.read { db in try AlbumDAO.fetchAlbumGroups(in: db) }
            .sorted {
                ($0.albumArtist.lowercased(), $0.album.lowercased())
                    < ($1.albumArtist.lowercased(), $1.album.lowercased())
            }
    }

    /// Report offline degli album incompleti (brani presenti < trackCount tag).
    /// Ordinati per numero di brani mancanti (decrescente).
    public func incompleteAlbums() throws -> [AlbumGroup] {
        try albumGroups()
            .filter { $0.completeness == .incomplete }
            .sorted { ($0.tagTrackCount - $0.actualCount) > ($1.tagTrackCount - $1.actualCount) }
    }

    // ── Fase D: verifica online completezza + cache ─────────────────────────────

    /// Info Store già in cache, indicizzate per albumKey.
    public func storeInfoByKey() throws -> [String: DBAlbumStoreInfo] {
        try db.read { db in
            try DBAlbumStoreInfo.fetchAll(db).reduce(into: [:]) { $0[$1.albumKey] = $1 }
        }
    }

    /// Scansiona online (iTunes) gli album senza tag trackCount per ottenere il
    /// conteggio autorevole, salvandolo in `album_store_info`. Ripristinabile:
    /// salta gli album già presenti in cache (salvo `force`). Cooperativamente
    /// cancellabile. ⚠️ Lento: ~3 s per album per rispettare i limiti iTunes.
    public func verifyAlbumsOnline(
        force: Bool = false,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        // Solo album senza tag (gli altri sono già valutabili offline) e mono-disco.
        let candidates = try albumGroups().filter { $0.completeness == .unknown }

        let cachedKeys: Set<String> = force ? [] : try db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT albumKey FROM album_store_info"))
        }
        let todo = candidates.filter { !cachedKeys.contains($0.key) }
        let total = todo.count
        var done = 0

        for g in todo {
            try Task.checkCancellation()
            do {
                let info: DBAlbumStoreInfo
                if let r = try await enrichment.lookupAlbum(albumArtist: g.albumArtist, album: g.album) {
                    info = DBAlbumStoreInfo(
                        albumKey: g.key, albumArtist: g.albumArtist, album: g.album,
                        collectionId: r.collectionId, storeTrackCount: r.storeTrackCount,
                        matchState: "found"
                    )
                } else {
                    info = DBAlbumStoreInfo(
                        albumKey: g.key, albumArtist: g.albumArtist, album: g.album,
                        matchState: "notFound"
                    )
                }
                try db.write { db in try info.upsert(db) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Errore di rete transitorio: non salviamo, così verrà ritentato.
                log.error("lookupAlbum fallito per \(g.album): \(error.localizedDescription)")
            }
            done += 1
            progress(done, total)
        }
        log.info("verifyAlbumsOnline: \(done)/\(total) album verificati")
    }

    // ── Fase D-bis: scrittura massiva trackCount/discCount ──────────────────────

    /// Candidato alla scrittura conteggi: album senza tag, verificato completo
    /// dallo Store (storeTrackCount == brani presenti), mono-disco.
    public struct AlbumCountFix: Sendable, Identifiable {
        public var id: String { albumKey }
        public let albumKey: String
        public let albumArtist: String
        public let album: String
        public let storeTrackCount: Int
        public let pids: [String]
    }

    /// Album «senza tag» risultati completi alla verifica online: candidati alla
    /// scrittura di `trackCount`/`discCount` su tutte le loro tracce.
    public func completeVerifiedWithoutTag() throws -> [AlbumCountFix] {
        let store = try storeInfoByKey()
        return try albumGroups().compactMap { g -> AlbumCountFix? in
            guard g.completeness == .unknown,
                  let info = store[g.key],
                  info.matchState == "found",
                  let total = info.storeTrackCount,
                  total == g.actualCount
            else { return nil }
            return AlbumCountFix(
                albumKey: g.key, albumArtist: g.albumArtist, album: g.album,
                storeTrackCount: total, pids: g.pids
            )
        }
        .sorted { ($0.albumArtist.lowercased(), $0.album.lowercased())
                < ($1.albumArtist.lowercased(), $1.album.lowercased()) }
    }

    /// Scrive `trackCount` (= valore Store) e `discCount = 1` su tutte le tracce
    /// degli album indicati. Mono-disco (Fase 1). Undo automatico via operation_log.
    public func writeTrackCounts(_ fixes: [AlbumCountFix]) async throws -> NormalizationResult {
        var updated = 0; var failed = 0; var errors: [(String, String)] = []
        for fix in fixes {
            let items: [(TrackMetadataUpdate, String)] = fix.pids.map { pid in
                var u = TrackMetadataUpdate()
                u.trackCount = fix.storeTrackCount
                u.discCount = 1
                return (u, pid)
            }
            let result = try await writeService.writeBatch(items)
            updated += result.succeeded.count
            failed += result.failed.count
            errors.append(contentsOf: result.failed)
        }
        return NormalizationResult(updated: updated, failed: failed, errors: errors)
    }

    // ── Fase E: diff durate caricato vs Store ───────────────────────────────────

    public struct DurationDiff: Sendable, Identifiable {
        public var id: String { persistentID }
        public let persistentID: String
        public let trackName: String
        public let localDuration: Double
        public let storeDuration: Double
        public var deltaSeconds: Double { abs(localDuration - storeDuration) }
    }

    /// Confronta la durata delle tracce «caricate» (uploaded) di un album con
    /// quelle dello Store, usando il `collectionId` in cache. Match per titolo
    /// (similarità token). Ritorna solo le differenze oltre `threshold` secondi.
    public func durationDiffs(for album: AlbumGroup, threshold: Double = 2.0) async throws -> [DurationDiff] {
        guard let info = try storeInfoByKey()[album.key],
              let collectionId = info.collectionId else { return [] }

        let localTracks: [DBTrack] = try db.read { db in
            try album.pids.compactMap { try TrackDAO.fetch(persistentID: $0, in: db) }
        }
        let uploaded = localTracks.filter { CloudStatus(code: $0.cloudStatus) == .uploaded }
        guard !uploaded.isEmpty else { return [] }

        let storeTracks = try await enrichment.lookupCollectionTracks(collectionId: collectionId)
        guard !storeTracks.isEmpty else { return [] }

        var diffs: [DurationDiff] = []
        for local in uploaded {
            // Match migliore per titolo
            var best: (sim: Double, store: EnrichmentService.StoreTrack)?
            for s in storeTracks {
                let sim = tokenSimilarity(local.name, s.trackName)
                if best == nil || sim > best!.sim { best = (sim, s) }
            }
            guard let b = best, b.sim >= 0.6 else { continue }
            let delta = abs(local.duration - b.store.durationSeconds)
            if delta > threshold {
                diffs.append(DurationDiff(
                    persistentID: local.persistentID,
                    trackName: local.name,
                    localDuration: local.duration,
                    storeDuration: b.store.durationSeconds
                ))
            }
        }
        return diffs.sorted { $0.deltaSeconds > $1.deltaSeconds }
    }

    // ── Fase F: fix disco/traccia mancanti (1 di 1) ─────────────────────────────

    /// Traccia candidata alla scrittura automatica disco/traccia 1 di 1.
    public struct TrackPositionFix: Sendable, Identifiable {
        public var id: String { persistentID }
        public let persistentID: String
        public let trackName: String
        public let albumArtist: String
        public let album: String
        public init(persistentID: String, trackName: String, albumArtist: String, album: String) {
            self.persistentID = persistentID
            self.trackName = trackName
            self.albumArtist = albumArtist
            self.album = album
        }
    }

    /// Tracce degli album (esclusi singoli) che mancano di trackNumber o discNumber.
    public func tracksWithMissingPositions() throws -> [TrackPositionFix] {
        try db.read { db in
            let sql = """
                SELECT persistentID, name, COALESCE(NULLIF(albumArtist,''), artist) AS dispArtist, album
                FROM track
                WHERE TRIM(album) != ''
                  AND album NOT LIKE '% - Single'
                  AND (trackNumber = 0 OR discNumber = 0)
                ORDER BY LOWER(COALESCE(NULLIF(albumArtist,''), artist)), LOWER(album), LOWER(name)
                """
            return try Row.fetchAll(db, sql: sql).map {
                TrackPositionFix(
                    persistentID: $0["persistentID"],
                    trackName: $0["name"] ?? "",
                    albumArtist: $0["dispArtist"] ?? "",
                    album: $0["album"] ?? ""
                )
            }
        }
    }

    /// Scrive `trackNumber = 1`, `trackCount = 1`, `discNumber = 1`, `discCount = 1`
    /// sulle tracce indicate. Undo automatico via operation_log.
    public func writePositions(_ fixes: [TrackPositionFix]) async throws -> NormalizationResult {
        let items: [(TrackMetadataUpdate, String)] = fixes.map { fix in
            var u = TrackMetadataUpdate()
            u.trackNumber = 1
            u.trackCount = 1
            u.discNumber = 1
            u.discCount = 1
            return (u, fix.persistentID)
        }
        let result = try await writeService.writeBatch(items)
        return NormalizationResult(
            updated: result.succeeded.count,
            failed: result.failed.count,
            errors: result.failed
        )
    }

    // ── Fase A: normalizzazione "- Single" ──────────────────────────────────────

    /// Appende `" - Single"` al campo `album` delle tracce indicate, scrivendo su Music.
    /// - Salta le tracce il cui album termina già con il suffisso.
    /// - Se `useTrackNameAsAlbum` è `true`, usa il nome del brano come base
    ///   (convenzione Apple `"<Titolo> - Single"`), altrimenti il valore album corrente.
    /// Ritorna `nil` se nessuna traccia era idonea.
    public func markAsSingle(
        pids: [String],
        useTrackNameAsAlbum: Bool = false
    ) async throws -> WriteResult? {
        let tracks: [DBTrack] = try db.read { db in
            try pids.compactMap { try TrackDAO.fetch(persistentID: $0, in: db) }
        }

        var items: [(TrackMetadataUpdate, String)] = []
        for t in tracks {
            let base = (useTrackNameAsAlbum ? t.name : t.album)
                .trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty else { continue }

            var u = TrackMetadataUpdate()
            // Aggiunge il suffisso solo se non già presente
            if !t.album.hasSuffix(Self.singleSuffix) {
                u.album = base + Self.singleSuffix
            }
            // Imposta sempre posizione 1/1
            u.trackNumber = 1
            u.trackCount  = 1
            u.discNumber  = 1
            u.discCount   = 1
            items.append((u, t.persistentID))
        }

        guard !items.isEmpty else {
            log.info("markAsSingle: nessuna traccia idonea su \(pids.count) selezionate")
            return nil
        }

        log.info("markAsSingle: \(items.count) tracce")
        return try await writeService.writeBatch(items)
    }
}
