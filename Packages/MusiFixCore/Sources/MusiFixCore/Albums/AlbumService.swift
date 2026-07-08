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

    /// Chiavi degli album "ignorati in MusiFix": esclusi dalla verifica completezza. (Fase 13)
    private func ignoredAlbumKeys() throws -> Set<String> {
        try db.read { try Set(String.fetchAll($0, sql: "SELECT albumKey FROM album_ignore")) }
    }

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
        let ignored = try ignoredAlbumKeys()
        return try albumGroups()
            .filter { $0.completeness == .incomplete && !ignored.contains($0.key) }
            .sorted { ($0.tagTrackCount - $0.actualCount) > ($1.tagTrackCount - $1.actualCount) }
    }

    // ── Report discografia: album completi per artista ──────────────────────────

    /// Voce di discografia: un album completo di un artista.
    public struct DiscographyAlbum: Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let album: String
        public let year: Int?
    }

    /// Artista con la sua discografia di album completi.
    public struct DiscographyArtist: Sendable, Identifiable {
        public var id: String { artist }
        public let artist: String
        public let albums: [DiscographyAlbum]
    }

    /// Report discografia: per ogni artista con almeno un album «completo»,
    /// l'elenco dei suoi album completi. «Completo» = tag `trackCount` combaciante
    /// (`.complete`) **oppure** album «senza tag» verificato completo su Store
    /// (`storeTrackCount == actualCount`). Esclude gli album ignorati in MusiFix.
    /// Ordinato per artista; all'interno per anno (album senza anno in fondo).
    public func discographyReport() throws -> [DiscographyArtist] {
        let ignored = try ignoredAlbumKeys()
        let store = try storeInfoByKey()

        func isComplete(_ g: AlbumGroup) -> Bool {
            switch g.completeness {
            case .complete:
                return true
            case .unknown:
                guard let info = store[g.key], info.matchState == "found",
                      let total = info.storeTrackCount else { return false }
                return g.actualCount == total
            default:
                return false
            }
        }

        let complete = try albumGroups().filter { !ignored.contains($0.key) && isComplete($0) }

        let byArtist = Dictionary(grouping: complete) { $0.albumArtist }
        return byArtist.map { artist, groups in
            let albums = groups
                .map { DiscographyAlbum(key: $0.key, album: $0.album, year: $0.year) }
                .sorted {
                    ($0.year ?? Int.max, $0.album.lowercased())
                        < ($1.year ?? Int.max, $1.album.lowercased())
                }
            return DiscographyArtist(artist: artist, albums: albums)
        }
        .sorted { $0.artist.lowercased() < $1.artist.lowercased() }
    }

    // ── Fase 22: report album mai/quasi mai riprodotti ──────────────────────────

    public struct UnplayedAlbum: Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let albumArtist: String
        public let album: String
        public let trackCount: Int
        public let totalPlays: Int
        public let playedTrackNames: [String]
        public let dateAdded: Date?

        public enum Kind: Sendable { case zero, partial }
        public var kind: Kind { totalPlays == 0 ? .zero : .partial }
    }

    /// Album con play totali <= `maxTotalPlays`, esclusi quelli aggiunti negli
    /// ultimi `graceDays` giorni e quelli ignorati in MusiFix. Include i
    /// cloud-only (Music traccia `playedCount` anche per tracce non scaricate).
    /// Richiede un giro di `IndexService.refreshPlayCounts()` per dati aggiornati
    /// (l'ascolto non sempre tocca `modificationDate`, quindi il sync
    /// incrementale può non accorgersene).
    public func unplayedAlbums(maxTotalPlays: Int, graceDays: Int) throws -> [UnplayedAlbum] {
        let ignored = try ignoredAlbumKeys()
        let cutoff = Calendar.current.date(byAdding: .day, value: -graceDays, to: Date()) ?? .distantPast
        let stats = try db.read { db in try AlbumDAO.fetchAlbumPlayStats(in: db) }
        return stats
            .filter { $0.totalPlays <= maxTotalPlays && !ignored.contains($0.key) }
            .filter { stat in
                guard let added = stat.dateAdded else { return true }
                return added <= cutoff
            }
            .map { s in
                UnplayedAlbum(key: s.key, albumArtist: s.albumArtist, album: s.album,
                              trackCount: s.trackCount, totalPlays: s.totalPlays,
                              playedTrackNames: s.playedTrackNames, dateAdded: s.dateAdded)
            }
            .sorted { ($0.albumArtist.lowercased(), $0.album.lowercased())
                    < ($1.albumArtist.lowercased(), $1.album.lowercased()) }
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
        // Solo album senza tag (gli altri sono già valutabili offline) e mono-disco,
        // esclusi gli album ignorati in MusiFix.
        let ignored = try ignoredAlbumKeys()
        let candidates = try albumGroups().filter {
            $0.completeness == .unknown && !ignored.contains($0.key)
        }

        let cachedKeys: Set<String> = force ? [] : try db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT albumKey FROM album_store_info"))
        }
        // Precedenza agli album con almeno 5 tracce in libreria cloud; gli altri
        // a seguire. Partizione stabile: preserva l'ordine relativo in ciascun gruppo.
        let todo = candidates.filter { !cachedKeys.contains($0.key) }
            .stablePartitioned { $0.actualCount >= 5 }
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
        let ignored = try ignoredAlbumKeys()
        return try albumGroups().compactMap { g -> AlbumCountFix? in
            guard g.completeness == .unknown,
                  !ignored.contains(g.key),
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

    // ── Fase G: allineamento numeri traccia/disco da Store ──────────────────────

    public enum TrackMatchConfidence: String, Sendable {
        case high       // verde: pre-spuntata
        case medium     // arancione: da rivedere
        case uncertain  // rosso: richiede conferma
        case unmatched  // rosso: nessun match, campi vuoti da compilare a mano
    }

    public struct PositionProposal: Sendable, Identifiable {
        public var id: String { persistentID }
        public let persistentID: String
        public let trackName: String
        // Valori correnti nel DB
        public let currentTrackNumber: Int
        public let currentTrackCount: Int
        public let currentDiscNumber: Int
        public let currentDiscCount: Int
        // Proposta (editabile dalla UI)
        public var proposedTrackNumber: Int?
        public var proposedTrackCount: Int?
        public var proposedDiscNumber: Int?
        public var proposedDiscCount: Int?
        // Diagnostica
        public let matchedStoreName: String?
        public let similarity: Double
        public let confidence: TrackMatchConfidence
    }

    public struct AlbumAlignment: Sendable {
        public let album: AlbumGroup
        public let candidate: EnrichmentService.AlbumLookupCandidate
        public let proposals: [PositionProposal]
    }

    /// Propone l'allineamento numeri per tutte le tracce di `album` rispetto
    /// all'edizione `candidate` recuperata da Store.
    /// Match 1:1 greedy per titolo (metrica ibrida disc-aware).
    public func proposeAlbumPositions(
        for album: AlbumGroup,
        candidate: EnrichmentService.AlbumLookupCandidate
    ) async throws -> AlbumAlignment {
        let storeTracks = try await enrichment.lookupCollectionTracks(collectionId: candidate.collectionId)
        let localTracks: [DBTrack] = try db.read { db in
            try album.pids.compactMap { try TrackDAO.fetch(persistentID: $0, in: db) }
        }
        // Ordine display: per-disco poi per-traccia (valori correnti, potrebbero essere 0)
        let sorted = localTracks.sorted {
            ($0.discNumber, $0.trackNumber, $0.name.lowercased())
                < ($1.discNumber, $1.trackNumber, $1.name.lowercased())
        }

        // Costruiamo la matrice similarità e facciamo il match greedy 1:1
        struct Pair { let lIdx: Int; let sIdx: Int; let sim: Double; let secondBest: Double }
        var pairs: [Pair] = []
        for (lIdx, local) in sorted.enumerated() {
            let coreLocal = trackTitleCore(local.name)
            var scores: [(sIdx: Int, sim: Double)] = []
            for (sIdx, store) in storeTracks.enumerated() {
                let sim = hybridTitleSimilarity(coreLocal, trackTitleCore(store.trackName))
                scores.append((sIdx, sim))
            }
            scores.sort { $0.sim > $1.sim }
            let best = scores.first?.sim ?? 0
            let second = scores.dropFirst().first?.sim ?? 0
            if best > 0, let top = scores.first {
                pairs.append(Pair(lIdx: lIdx, sIdx: top.sIdx, sim: best, secondBest: second))
            }
        }
        // Greedy: ordine score decrescente, ogni store track usato una volta
        pairs.sort { $0.sim > $1.sim }
        var usedLocal = Set<Int>(); var usedStore = Set<Int>()
        var assignment: [Int: (sIdx: Int, sim: Double, secondBest: Double)] = [:]
        for p in pairs {
            if usedLocal.contains(p.lIdx) || usedStore.contains(p.sIdx) { continue }
            assignment[p.lIdx] = (p.sIdx, p.sim, p.secondBest)
            usedLocal.insert(p.lIdx); usedStore.insert(p.sIdx)
        }

        // Calcola trackCount per-disco dallo store
        var trackCountPerDisc: [Int: Int] = [:]
        for s in storeTracks {
            let d = s.discNumber
            let tc = s.trackCount > 0 ? s.trackCount : (storeTracks.filter { $0.discNumber == d }.map(\.trackNumber).max() ?? 0)
            trackCountPerDisc[d] = max(trackCountPerDisc[d] ?? 0, tc)
        }
        let storeDiscCount = storeTracks.map(\.discCount).max() ?? 1

        // Post-pass: rileva duplicati (disco,traccia) proposti
        var proposedPositions = Set<String>()
        var duplicateLocalIdxs = Set<Int>()
        for (lIdx, match) in assignment {
            let s = storeTracks[match.sIdx]
            let key = "\(s.discNumber):\(s.trackNumber)"
            if proposedPositions.contains(key) {
                duplicateLocalIdxs.insert(lIdx)
            } else {
                proposedPositions.insert(key)
            }
        }

        // Assembla i proposal
        var proposals: [PositionProposal] = sorted.enumerated().map { (lIdx, local) in
            if let match = assignment[lIdx], !duplicateLocalIdxs.contains(lIdx) {
                let store = storeTracks[match.sIdx]
                let s = match.sim
                let delta = s - match.secondBest
                let qualLocal = hasQualifier(local.name)
                let qualStore = hasQualifier(store.trackName)
                let qualMismatch = qualLocal != qualStore
                let mutual: Bool = {
                    // il match store ha scelto questo local come suo best?
                    var bestForStore: (lIdx: Int, sim: Double)?
                    for (l2, m2) in assignment where m2.sIdx == match.sIdx {
                        if bestForStore == nil || m2.sim > bestForStore!.sim { bestForStore = (l2, m2.sim) }
                    }
                    return bestForStore?.lIdx == lIdx
                }()
                let confidence: TrackMatchConfidence
                if s >= 0.80 && (delta >= 0.25 || mutual) && !qualMismatch {
                    confidence = .high
                } else if s >= 0.55 {
                    confidence = .medium
                } else {
                    confidence = .uncertain
                }
                let tc = trackCountPerDisc[store.discNumber] ?? store.trackCount
                return PositionProposal(
                    persistentID: local.persistentID,
                    trackName: local.name,
                    currentTrackNumber: local.trackNumber,
                    currentTrackCount: local.trackCount,
                    currentDiscNumber: local.discNumber,
                    currentDiscCount: local.discCount,
                    proposedTrackNumber: store.trackNumber > 0 ? store.trackNumber : nil,
                    proposedTrackCount: tc > 0 ? tc : nil,
                    proposedDiscNumber: store.discNumber,
                    proposedDiscCount: storeDiscCount,
                    matchedStoreName: store.trackName,
                    similarity: s,
                    confidence: confidence
                )
            } else {
                return PositionProposal(
                    persistentID: local.persistentID,
                    trackName: local.name,
                    currentTrackNumber: local.trackNumber,
                    currentTrackCount: local.trackCount,
                    currentDiscNumber: local.discNumber,
                    currentDiscCount: local.discCount,
                    proposedTrackNumber: nil,
                    proposedTrackCount: nil,
                    proposedDiscNumber: nil,
                    proposedDiscCount: nil,
                    matchedStoreName: nil,
                    similarity: 0,
                    confidence: duplicateLocalIdxs.contains(lIdx) ? .uncertain : .unmatched
                )
            }
        }

        // Riordina per (disco proposto, traccia proposta, nome)
        proposals.sort {
            let d0 = $0.proposedDiscNumber ?? 99, d1 = $1.proposedDiscNumber ?? 99
            let t0 = $0.proposedTrackNumber ?? 999, t1 = $1.proposedTrackNumber ?? 999
            return (d0, t0, $0.trackName.lowercased()) < (d1, t1, $1.trackName.lowercased())
        }
        return AlbumAlignment(album: album, candidate: candidate, proposals: proposals)
    }

    /// Scrive i numeri proposti (solo le tracce con tutti e 4 i valori valorizzati).
    /// Undo automatico via operation_log.
    public func writeProposedPositions(_ proposals: [PositionProposal]) async throws -> WriteResult {
        let items: [(TrackMetadataUpdate, String)] = proposals.compactMap { p in
            guard let tn = p.proposedTrackNumber, let tc = p.proposedTrackCount,
                  let dn = p.proposedDiscNumber,  let dc = p.proposedDiscCount
            else { return nil }
            var u = TrackMetadataUpdate()
            u.trackNumber = tn; u.trackCount = tc
            u.discNumber  = dn; u.discCount  = dc
            return (u, p.persistentID)
        }
        guard !items.isEmpty else {
            return WriteResult(batchID: UUID().uuidString, succeeded: [], failed: [])
        }
        return try await writeService.writeBatch(items)
    }

    // ── Helpers matching Fase G ──────────────────────────────────────────────────

    /// Normalizza un titolo di traccia: fold diacritici, strip qualificatori
    /// tra parentesi/quadre, suffissi dopo " - ", feat./ft./with.
    /// Ritorna il core minuscolo senza punteggiatura.
    private func trackTitleCore(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // strip (...) e [...]
        t = t.replacing(#/\([^)]*\)/#, with: "")
        t = t.replacing(#/\[[^\]]*\]/#, with: "")
        // strip tutto dopo " - "
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        // strip feat./ft./with ...
        t = t.replacing(#/\s+(feat|ft|with)\b.*$/#, with: "")
        // normalizza & -> and, rimuovi punteggiatura residua
        t = t.replacingOccurrences(of: "&", with: "and")
        t = t.replacingOccurrences(of: "'", with: "")
        // tokenizza e riunisci (rimuove spazi multipli)
        let tokens = t.components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters))
                      .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    /// True se il titolo contiene qualificatori espliciti (Live, Remastered, ecc.).
    private func hasQualifier(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("(") || lower.contains("[") ||
               lower.range(of: #"\s+-\s+"#, options: .regularExpression) != nil
    }

    /// Similarità ibrida tra due core già normalizzati: max(Jaccard, 1−Levenshtein/maxLen).
    private func hybridTitleSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let j = jaccardTokens(a, b)
        let l = 1.0 - Double(levenshtein(a, b)) / Double(max(a.count, b.count))
        return max(j, l)
    }

    private func jaccardTokens(_ a: String, _ b: String) -> Double {
        let ta = Set(a.components(separatedBy: " ").filter { !$0.isEmpty })
        let tb = Set(b.components(separatedBy: " ").filter { !$0.isEmpty })
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }; if n == 0 { return m }
        var row = Array(0...n)
        for i in 1...m {
            var prev = row[0]; row[0] = i
            for j in 1...n {
                let old = row[j]
                row[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, row[j], row[j-1])
                prev = old
            }
        }
        return row[n]
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

    // ── Fase 14: editing massivo campi album ────────────────────────────────────

    /// Carica le tracce (DBTrack) per un insieme di persistentID.
    /// Usato dalla UI per calcolare i valori comuni e l'anteprima diff.
    public func tracks(forPids pids: [String]) throws -> [DBTrack] {
        try db.read { db in
            try pids.compactMap { try TrackDAO.fetch(persistentID: $0, in: db) }
        }
    }

    /// Generi distinti già presenti in libreria (per suggerimenti nella UI).
    public func distinctGenres() throws -> [String] {
        try db.read { db in try TrackDAO.fetchDistinctGenres(in: db) }
    }

    /// Applica un edit di campi a livello album (tipicamente albumArtist / anno /
    /// genere) a tutte le tracce indicate. Scrive solo i campi non-nil in `update`.
    /// Undo automatico via operation_log.
    public func writeAlbumFields(pids: [String], update: TrackMetadataUpdate) async throws -> WriteResult {
        let items: [(TrackMetadataUpdate, String)] = pids.map { (update, $0) }
        guard !items.isEmpty else {
            return WriteResult(batchID: UUID().uuidString, succeeded: [], failed: [])
        }
        log.info("writeAlbumFields: \(items.count) tracce")
        return try await writeService.writeBatch(items)
    }
}

private extension Array {
    /// Partiziona in modo stabile: prima gli elementi che soddisfano `predicate`
    /// (nell'ordine originale), poi gli altri (nell'ordine originale).
    func stablePartitioned(by predicate: (Element) -> Bool) -> [Element] {
        var matching: [Element] = []
        var rest: [Element] = []
        for e in self {
            if predicate(e) { matching.append(e) } else { rest.append(e) }
        }
        return matching + rest
    }
}
