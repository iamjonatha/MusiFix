import Foundation
import Persistence
import GRDB
import OSLog
import CommonCrypto
import AVFoundation

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

        // Tutti i persistentID visti in Music in questa passata: serve per il pruning
        // finale dei brani eliminati da Music (vengono raccolti anche quelli saltati
        // dal checkpoint, così il pruning è corretto pure su ripresa interrotta).
        var seenPIDs = Set<String>()
        seenPIDs.reserveCapacity(total)

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
                seenPIDs.insert(track.persistentID)
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

        // 3b. Pruning: elimina dall'indice i brani non più presenti in Music.
        // Sicuro solo qui: il ciclo è arrivato in fondo a tutti i chunk senza
        // cancellazione, quindi `seenPIDs` rappresenta l'intera libreria Music.
        let dbPIDs: Set<String> = try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT persistentID FROM track"))
        }
        let removedPIDs = dbPIDs.subtracting(seenPIDs)
        if !removedPIDs.isEmpty {
            let snapshot = Array(removedPIDs)
            try db.write { db in
                for pid in snapshot { try TrackDAO.delete(persistentID: pid, in: db) }
            }
            log.info("Pruning: rimossi \(removedPIDs.count) brani eliminati da Music")
        }

        // 4. Risolvi path via filesystem scan (evita la risoluzione alias HFS+ lenta)
        if let mediaFolder = Self.musicMediaFolderURL() {
            try await resolveLocations(mediaFolder: mediaFolder, total: processed)
        }

        // I trigger FTS (track_fts_ai/au/ad, vedi migrazione v1_fts5) mantengono
        // l'indice full-text a ogni INSERT/UPDATE/DELETE del ciclo sopra: nessun
        // rebuild finale necessario (era lavoro duplicato).

        // 5. Marca sync completata
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

        // Snapshot delle modDate note nell'indice (persistentID → modDate?).
        let knownModDates = try db.read { db in
            try TrackDAO.fetchModDates(in: db)
        }

        let total = try await bulkFetcher.trackCount()
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: total, lastSyncDate: nil))

        // Passata leggera a blocchi: per ogni chunk leggiamo solo (pid, modDate) via
        // trackIdentitiesChunk e decidiamo quali brani sono nuovi/modificati. Solo i
        // chunk "sporchi" (con almeno un brano da aggiornare) vengono ri-letti per
        // intero con tracksChunk. Un sync con pochi cambiamenti costa così ~2
        // proprietà × N chunk invece di ~19 × N. Il rilevamento delle modifiche ora
        // funziona davvero: prima la modification date non veniva nemmeno letta dal
        // fetch bulk, quindi solo nuovi/rimossi venivano rilevati.
        var musicPIDs = Set<String>()
        musicPIDs.reserveCapacity(total)
        var toUpsert: [DBTrack] = []
        var added = 0
        var updated = 0
        let tolerance = 1.0   // s: assorbe l'arrotondamento epoch lato AppleScript

        let chunkSize = 1000
        var chunkStart = 1
        var scanned = 0
        while chunkStart <= total {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + chunkSize - 1, total)
            let idents = try await bulkFetcher.trackIdentitiesChunk(from: chunkStart, to: chunkEnd)

            var dirtyPIDs = Set<String>()
            for (pid, modEpoch) in idents {
                musicPIDs.insert(pid)
                guard let known = knownModDates[pid] else {
                    dirtyPIDs.insert(pid)            // assente nell'indice → nuovo
                    continue
                }
                guard let storedDate = known else {
                    // Riga legacy senza modDate (indicizzata prima di questa modifica):
                    // ri-leggila una volta per popolarla; i sync successivi la salteranno
                    // finché non cambia davvero.
                    dirtyPIDs.insert(pid)
                    continue
                }
                if let modEpoch, modEpoch - storedDate.timeIntervalSince1970 > tolerance {
                    dirtyPIDs.insert(pid)            // modificato
                }
            }

            if !dirtyPIDs.isEmpty {
                let full = try await bulkFetcher.tracksChunk(from: chunkStart, to: chunkEnd)
                for track in full where dirtyPIDs.contains(track.persistentID) {
                    if knownModDates[track.persistentID] == nil { added += 1 } else { updated += 1 }
                    toUpsert.append(await buildDBTrack(from: track))
                }
            }

            scanned += idents.count
            chunkStart = chunkEnd + 1
            setProgress(.init(phase: .fetchingFromMusic, processed: scanned, total: total, lastSyncDate: nil))
        }

        // Track rimossi da Music
        let removedPIDs = Set(knownModDates.keys).subtracting(musicPIDs)
        let removed = removedPIDs.count

        // Applica delta — snapshot locale per Sendable closure. Scriviamo sempre, anche
        // a delta vuoto, per aggiornare la data di ultima sync.
        let upsertSnapshot = toUpsert
        let removedSnapshot = removedPIDs
        try db.write { db in
            for track in upsertSnapshot {
                try TrackDAO.upsert(track, in: db)
            }
            for pid in removedSnapshot {
                try TrackDAO.delete(persistentID: pid, in: db)
            }
            try SyncStateDAO.setLastMusicSync(Date(), in: db)
        }

        let syncDate = Date()
        log.info("Sync incrementale: +\(added) ~\(updated) -\(removed)")
        setProgress(.init(
            phase: .done,
            processed: added + updated + removed,
            total: total,
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

        let indexes = await Self.buildMediaIndexes(mediaFolderPath: mediaFolder.path)
        log.info("File audio trovati nell'indice: \(indexes.byArtistAlbumTrack.count)")

        // Carica dal DB i brani senza path. Include anche quelli marcati isCloudOnly=1
        // da una sync precedente: il flag potrebbe essere stale (es. brano abbinato/
        // caricato che è stato poi scaricato localmente). Il filesystem è la fonte di
        // verità: se il file c'è → locale; se non c'è → cloud-only.
        struct TrackRow: Sendable {
            let pid: String; let name: String; let artist: String; let albumArtist: String
            let album: String; let trackNum: Int; let duration: Double
        }
        let tracksToResolve: [TrackRow] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, name, artist, albumArtist, album, trackNumber, duration
                FROM track WHERE locationPath IS NULL
                """)
                .map { TrackRow(pid: $0["persistentID"] ?? "",
                                name: $0["name"] ?? "",
                                artist: $0["artist"] ?? "",
                                albumArtist: $0["albumArtist"] ?? "",
                                album: $0["album"] ?? "",
                                trackNum: $0["trackNumber"] ?? 0,
                                duration: $0["duration"] ?? 0) }
        }

        var updates: [(pid: String, path: String)] = []
        var resolvedPIDs = Set<String>()
        for t in tracksToResolve {
            // Music.app usa albumArtist come cartella artista per le compilation
            let folderArtist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
            if let path = indexes.byArtistAlbumTrack[Self.locationKey(artist: folderArtist, album: t.album, trackNum: t.trackNum)]
                ?? indexes.byArtistAlbumTrack[Self.locationKey(artist: t.artist, album: t.album, trackNum: t.trackNum)] {
                updates.append((t.pid, path)); resolvedPIDs.insert(t.pid)
            }
        }
        log.info("Path risolti via euristica Artista/Album/NN: \(updates.count)/\(tracksToResolve.count)")

        // Brani non trovati dall'euristica esatta: layout non standard (compilation
        // sotto Compilations/, singoli sciolti Artista/Titolo, nomi sanitizzati da
        // Music, prefissi disco "1-08") o brani della Libreria iCloud (`shared track`)
        // per cui Music non espone `location` via AppleScript. Per tutti questi il
        // match per TITOLO sul filesystem è l'unica via affidabile (la `location` di
        // Music è lenta/bloccante su volumi esterni e vuota per gli shared track).
        // Durate dei file nei bucket di titolo ambigui, per separare gli omonimi.
        var ambiguousPaths = Set<String>()
        for t in tracksToResolve where !resolvedPIDs.contains(t.pid) {
            let bucket = indexes.byTitle[Self.normKey(t.name)] ?? []
            if bucket.count > 1 { for e in bucket { ambiguousPaths.insert(e.path) } }
        }
        let fileDurations = await Self.readDurations(paths: ambiguousPaths)

        for t in tracksToResolve where !resolvedPIDs.contains(t.pid) {
            guard let path = Self.matchAudioFile(name: t.name, artist: t.artist,
                                                 albumArtist: t.albumArtist, album: t.album,
                                                 trackNum: t.trackNum, duration: t.duration,
                                                 in: indexes.byTitle, fileDurations: fileDurations),
                  FileManager.default.fileExists(atPath: path) else { continue }
            updates.append((t.pid, path)); resolvedPIDs.insert(t.pid)
        }
        log.info("Path totali risolti via filesystem: \(updates.count)/\(tracksToResolve.count)")

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

    // ── Scansione appartenenza a playlist (inPlaylist) ────────────────────────

    /// Popola la colonna `inPlaylist` (0/1) interrogando Music.app per i brani che
    /// appartengono ad almeno una playlist "normale" (escluse smart/cartelle/speciali).
    /// On-demand come la scansione copertine; va rieseguita dopo modifiche alle playlist.
    @discardableResult
    public func scanPlaylistMembership() async throws -> Int {
        log.info("Scansione playlist avviata")
        setProgress(.init(phase: .fetchingFromMusic, processed: 0, total: 0, lastSyncDate: nil))

        let members = try await bridge.tracksInRegularPlaylists()
        let memberArray = Array(members)

        let marked = try db.write { db -> Int in
            // Azzera tutti, poi marca i membri a blocchi (limite variabili SQLite).
            try db.execute(sql: "UPDATE track SET inPlaylist = 0")
            var updated = 0
            let chunkSize = 900
            var i = 0
            while i < memberArray.count {
                let chunk = Array(memberArray[i..<min(i + chunkSize, memberArray.count)])
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "UPDATE track SET inPlaylist = 1 WHERE persistentID IN (\(ph))",
                               arguments: StatementArguments(chunk.map { DatabaseValue(value: $0) }))
                updated += db.changesCount
                i += chunkSize
            }
            return updated
        }

        setProgress(.init(phase: .done, processed: marked, total: marked, lastSyncDate: nil))
        log.info("Scansione playlist completata: \(marked) brani in almeno una playlist")
        return marked
    }

    // ── Scansione stato iCloud (cloudStatus) ──────────────────────────────────

    /// Popola la colonna `cloudStatus` leggendo lo stato iCloud reale da Music
    /// (Abbinato/Caricato/Acquistato/Apple Music/…). Veloce: solo persistentID +
    /// cloud status a blocchi (~1 Apple Event per proprietà per chunk). Necessaria
    /// perché il fetch bulk storico non popolava il campo; va rieseguita dopo
    /// cambi di stato lato Apple Music. Le nuove indicizzazioni complete lo
    /// includono già automaticamente.
    @discardableResult
    public func scanCloudStatus() async throws -> Int {
        let total = try await bulkFetcher.trackCount()
        log.info("Scansione stato cloud avviata: \(total) brani")
        setProgress(.init(phase: .enrichingFiles(completed: 0, total: total),
                          processed: 0, total: total, lastSyncDate: nil))

        let chunkSize = 1000
        var start = 1
        var scanned = 0
        while start <= total {
            try Task.checkCancellation()
            let end = min(start + chunkSize - 1, total)
            let rows = try await bulkFetcher.cloudStatusChunk(from: start, to: end)
            let snapshot = rows
            try db.write { db in
                for (pid, code) in snapshot {
                    try db.execute(sql: "UPDATE track SET cloudStatus=? WHERE persistentID=?",
                                   arguments: [code, pid])
                }
            }
            scanned += rows.count
            start = end + 1
            setProgress(.init(phase: .enrichingFiles(completed: scanned, total: total),
                              processed: scanned, total: total, lastSyncDate: nil))
        }
        log.info("Scansione stato cloud completata: \(scanned) brani")
        setProgress(.init(phase: .done, processed: scanned, total: total, lastSyncDate: nil))
        return scanned
    }

    // ── Riparazione mirata brani marcati cloud-only ───────────────────────────

    /// Recupera la location reale per i brani attualmente marcati `isCloudOnly`
    /// (file non trovato dall'euristica filesystem). Più veloce di un re-index
    /// completo: non rifà il fetch dei 25k brani, agisce solo sul sottoinsieme
    /// cloud-only. I brani il cui file viene ritrovato sul disco tornano
    /// editabili; gli altri restano cloud-only (cloud reali).
    ///
    /// Usa la scansione filesystem (come `resolveLocations`) e NON la risoluzione
    /// degli alias di Music (`location of t`): quest'ultima si blocca su volumi
    /// esterni con catalogo inconsistente (FSFindFolder -43 / FileIDTree -35).
    @discardableResult
    public func repairCloudOnlyLocations() async throws -> Int {
        struct CloudRow: Sendable {
            let pid: String; let name: String; let artist: String
            let albumArtist: String; let album: String; let trackNum: Int; let duration: Double
        }
        let candidates: [CloudRow] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, name, artist, albumArtist, album, trackNumber, duration
                FROM track WHERE isCloudOnly=1
                """)
                .map { CloudRow(pid: $0["persistentID"] ?? "",
                                name: $0["name"] ?? "",
                                artist: $0["artist"] ?? "",
                                albumArtist: $0["albumArtist"] ?? "",
                                album: $0["album"] ?? "",
                                trackNum: $0["trackNumber"] ?? 0,
                                duration: $0["duration"] ?? 0) }
        }
        log.info("Riparazione cloud-only: \(candidates.count) candidati")
        guard !candidates.isEmpty else {
            setProgress(.init(phase: .done, processed: 0, total: 0, lastSyncDate: nil))
            return 0
        }
        guard let mediaFolder = Self.musicMediaFolderURL() else {
            throw MusiFixError.appleScriptError(
                "Cartella media di Music non trovata nelle preferenze (media-folder-url)")
        }
        setProgress(.init(phase: .resolvingLocations(resolved: 0, total: candidates.count),
                          processed: 0, total: candidates.count, lastSyncDate: nil))

        // Indice per TITOLO normalizzato → file. La struttura su disco è eterogenea
        // (Artista/Album/NN, Artista/Titolo sciolto, Compilations/Album/[D-]NN, nomi
        // sanitizzati da Music): l'euristica Artista/Album/NN fallisce. Il titolo
        // estratto dal filename è il segnale più stabile; disambiguiamo le collisioni
        // con cartella album + numero traccia, e in caso di parità saltiamo (sicuro).
        let indexes = await Self.buildMediaIndexes(mediaFolderPath: mediaFolder.path)
        log.info("File audio indicizzati: \(indexes.byTitle.count) titoli distinti")

        // Durate dei soli file in bucket di titolo ambigui (>1 candidato): servono a
        // separare i brani omonimi (vedi matchAudioFile).
        var ambiguousPaths = Set<String>()
        for t in candidates {
            let bucket = indexes.byTitle[Self.normKey(t.name)] ?? []
            if bucket.count > 1 { for e in bucket { ambiguousPaths.insert(e.path) } }
        }
        let fileDurations = await Self.readDurations(paths: ambiguousPaths)

        var repaired: [(pid: String, path: String)] = []
        for t in candidates {
            guard let path = Self.matchAudioFile(name: t.name, artist: t.artist,
                                                 albumArtist: t.albumArtist, album: t.album,
                                                 trackNum: t.trackNum, duration: t.duration,
                                                 in: indexes.byTitle, fileDurations: fileDurations),
                  FileManager.default.fileExists(atPath: path) else { continue }
            repaired.append((t.pid, path))
        }
        log.info("Location recuperate via filesystem: \(repaired.count)/\(candidates.count)")

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

        setProgress(.init(phase: .done, processed: repaired.count, total: candidates.count, lastSyncDate: nil))
        return repaired.count
    }

    // ── Indici filesystem per la risoluzione dei path ─────────────────────────

    struct AudioFileEntry: Sendable {
        let path: String
        let trackNum: Int
        let albumFolderNorm: String
        let artistFolderNorm: String
    }

    struct MediaIndexes: Sendable {
        /// `(artist_folder, album_folder, trackNum) → path`: match esatto sulla
        /// struttura standard `Artist/Album/NN Title.ext`.
        let byArtistAlbumTrack: [String: String]
        /// `titolo normalizzato → [file]`: fallback per layout non standard
        /// (compilation, singoli sciolti, nomi sanitizzati). Vedi `matchAudioFile`.
        let byTitle: [String: [AudioFileEntry]]
    }

    /// Scansiona una sola volta la cartella media e costruisce entrambi gli indici
    /// (per percorso e per titolo). Eseguito in `Task.detached` (DirectoryEnumerator
    /// non è Sendable in async). Evita la risoluzione degli alias HFS+ via AppleScript
    /// che può bloccarsi su volumi esterni con catalogo inconsistente
    /// (FileIDTreeGetAndLockVolumeEntryFromIndex -35) e che per i brani della Libreria
    /// iCloud (`shared track`) restituisce comunque `missing value`.
    /// Estensioni dei file considerati audio durante la scansione filesystem.
    /// Fonte di verità unica condivisa con `OrphanScanService`.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "aiff", "aif", "wav", "alac", "ogg", "opus", "wma"]

    static func buildMediaIndexes(mediaFolderPath: String) async -> MediaIndexes {
        let audioExtensions = Self.audioExtensions
        return await Task.detached(priority: .userInitiated) {
            var pathIdx: [String: String] = [:]
            var titleIdx: [String: [AudioFileEntry]] = [:]
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: mediaFolderPath),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return MediaIndexes(byArtistAlbumTrack: pathIdx, byTitle: titleIdx) }
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let stem = fileURL.deletingPathExtension().lastPathComponent
                let albumFolder = fileURL.deletingLastPathComponent().lastPathComponent
                let artistFolder = fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

                // Indice esatto (artista, album, traccia)
                let leadNum = IndexService.parseLeadingTrackNumber(from: stem)
                let pathKey = IndexService.locationKey(artist: artistFolder, album: albumFolder, trackNum: leadNum)
                if pathIdx[pathKey] == nil { pathIdx[pathKey] = fileURL.path }

                // Indice per titolo (sia titolo spogliato del prefisso traccia sia nome
                // completo, per coprire i titoli che iniziano davvero con un numero)
                let (tnum, title) = IndexService.parseTrackAndTitle(stem: stem)
                let entry = AudioFileEntry(path: fileURL.path, trackNum: tnum,
                                           albumFolderNorm: IndexService.normKey(albumFolder),
                                           artistFolderNorm: IndexService.normKey(artistFolder))
                for key in Set([IndexService.normKey(title), IndexService.normKey(stem)]) where !key.isEmpty {
                    titleIdx[key, default: []].append(entry)
                }
            }
            return MediaIndexes(byArtistAlbumTrack: pathIdx, byTitle: titleIdx)
        }.value
    }

    /// Chiave normalizzata per il match per titolo: rimuove diacritici, porta in
    /// minuscolo e collassa qualsiasi sequenza non alfanumerica-ASCII in un singolo
    /// spazio. Rende equivalenti varianti di punteggiatura/apostrofi (`Don't`/`Don’t`/
    /// `Don_t`) e nomi sanitizzati da Music.
    static func normKey(_ s: String) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        var out = ""
        var pendingSpace = false
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            } else if !out.isEmpty {
                pendingSpace = true
            }
        }
        return out
    }

    /// Estrae numero di traccia e titolo dal nome file (senza estensione).
    /// `"08 Title"` → (8, "Title"); `"1-04 Title"` → (4, "Title"); `"Title"` → (0, "Title").
    static func parseTrackAndTitle(stem: String) -> (track: Int, title: String) {
        let chars = Array(stem)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        var j = i
        while j < chars.count, chars[j].isNumber { j += 1 }
        guard j > i else { return (0, stem) }
        let firstNum = Int(String(chars[i..<j])) ?? 0

        // Forma disco-traccia: "D - NN <spazio>"
        var k = j
        while k < chars.count, chars[k] == " " { k += 1 }
        if k < chars.count, chars[k] == "-" {
            k += 1
            while k < chars.count, chars[k] == " " { k += 1 }
            var m = k
            while m < chars.count, chars[m].isNumber { m += 1 }
            if m > k, m < chars.count, chars[m] == " " {
                let trackNum = Int(String(chars[k..<m])) ?? 0
                var t = m
                while t < chars.count, chars[t] == " " { t += 1 }
                return (trackNum, String(chars[t...]))
            }
        }
        // Forma traccia semplice: "NN <spazio>"
        if j < chars.count, chars[j] == " " {
            var t = j
            while t < chars.count, chars[t] == " " { t += 1 }
            return (firstNum, String(chars[t...]))
        }
        return (0, stem)
    }

    /// Sceglie il file corrispondente a un brano (per titolo), disambiguando le
    /// collisioni con cartella artista, cartella album, numero traccia e — decisivo —
    /// la DURATA: due brani distinti con lo stesso titolo (es. due "It's Like That" da
    /// 249s e 498s) vengono mappati ognuno al proprio file. Conservativo: se nessun
    /// candidato ha durata compatibile, o resta ambiguo, restituisce `nil` (brano non
    /// riparato) per non puntare al file sbagliato.
    ///
    /// `fileDurations`: durate (s) dei file candidati nei bucket ambigui (vedi
    /// `readDurations`); per i bucket a candidato unico non serve.
    static func matchAudioFile(name: String, artist: String, albumArtist: String,
                               album: String, trackNum: Int, duration: Double,
                               in index: [String: [AudioFileEntry]],
                               fileDurations: [String: Double]) -> String? {
        let cands = index[normKey(name)] ?? []
        if cands.isEmpty { return nil }
        if cands.count == 1 { return cands[0].path }
        let albNorm = normKey(album)
        let artNorm = normKey(artist)
        let albArtNorm = normKey(albumArtist)
        // La cartella artista è spesso sanitizzata o arricchita di collaboratori
        // ("Sister Nancy_King Tubby"): accetta il match per contenimento in entrambe
        // le direzioni contro artist o albumArtist.
        func artistMatches(_ folder: String) -> Bool {
            guard !folder.isEmpty else { return false }
            for a in [artNorm, albArtNorm] where !a.isEmpty {
                if folder == a || folder.contains(a) || a.contains(folder) { return true }
            }
            return false
        }
        var bestScore = -1
        var top: [AudioFileEntry] = []
        for c in cands {
            var score = 0
            if !albNorm.isEmpty, c.albumFolderNorm == albNorm { score += 2 }
            if artistMatches(c.artistFolderNorm) { score += 2 }
            if trackNum > 0, c.trackNum == trackNum { score += 1 }
            if score > bestScore { bestScore = score; top = [c] }
            else if score == bestScore { top.append(c) }
        }
        guard bestScore > 0 else { return nil }
        if top.count == 1 { return top[0].path }

        // Parità su artista/album/traccia: separa per DURATA. Tieni solo i file la cui
        // durata combacia con quella del brano (entro tolleranza). Quel che resta è lo
        // stesso brano in formati diversi → scegli l'm4a di Apple Music.
        guard duration > 0 else { return nil }
        let tolerance = 4.0
        let within = top.filter { c in
            guard let fd = fileDurations[c.path] else { return false }
            return abs(fd - duration) <= tolerance
        }
        // Se i file compatibili appartengono a più cartelle artista+album diverse, sono
        // canzoni diverse con durata simile: troppo rischioso, non riparare.
        let folders = Set(within.map { "\($0.artistFolderNorm)\u{1}\($0.albumFolderNorm)" })
        guard folders.count == 1 else { return nil }
        return within.sorted {
            let r0 = Self.formatRank($0.path), r1 = Self.formatRank($1.path)
            return r0 != r1 ? r0 < r1 : $0.path < $1.path
        }.first?.path
    }

    /// Priorità di formato quando lo stesso brano esiste in più file: preferisce
    /// l'm4a (file scaricato da Apple Music) ai formati importati a parte.
    static func formatRank(_ path: String) -> Int {
        switch (path as NSString).pathExtension.lowercased() {
        case "m4a", "m4p": return 0
        case "aac", "alac": return 1
        case "flac": return 2
        default: return 9
        }
    }

    /// Legge in parallelo la durata (s) dei file indicati via AVFoundation. Usato solo
    /// per i file candidati nei bucket di titolo ambigui, così il costo è limitato.
    static func readDurations(paths: Set<String>) async -> [String: Double] {
        guard !paths.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Double?).self) { group in
            for p in paths {
                group.addTask {
                    let asset = AVURLAsset(url: URL(fileURLWithPath: p))
                    guard let cm = try? await asset.load(.duration) else { return (p, nil) }
                    let secs = CMTimeGetSeconds(cm)
                    return (p, secs.isFinite && secs > 0 ? secs : nil)
                }
            }
            var out: [String: Double] = [:]
            for await (p, d) in group { if let d { out[p] = d } }
            return out
        }
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

    private func setProgress(_ p: IndexProgress) {
        progress = p
        progressContinuation?.yield(p)
    }
}

