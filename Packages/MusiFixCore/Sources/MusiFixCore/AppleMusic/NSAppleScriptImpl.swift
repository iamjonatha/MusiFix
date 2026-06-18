import Foundation

/// Implementazione fallback via NSAppleScript.
/// Usata quando ScriptingBridge non è disponibile (regressioni macOS / sandbox).
public final class NSAppleScriptImpl: AppleMusicBridge, @unchecked Sendable {

    public init() {}

    // NOTA: trackRowAppleScript non è più usato per il fetch bulk a blocchi.
    // tracksChunk usa fetch di lista (property of every item) → 17 Apple Events
    // per chunk invece di 17.000. Mantenuto solo per allTracks() legacy.

    // ─── allTracks ──────────────────────────────────────────────────────────

    public func allTracks() async throws -> [Track] {
        // Delega a tracksChunk in blocchi di 1000 per coerenza
        let total = try await trackCount()
        var result: [Track] = []
        result.reserveCapacity(total)
        var start = 1
        while start <= total {
            let end = min(start + 999, total)
            result.append(contentsOf: try await tracksChunk(from: start, to: end))
            start = end + 1
        }
        return result
    }

    // ─── trackCount / tracksChunk (fetch bulk a blocchi) ───────────────────

    /// Conta i brani in libreria con un singolo Apple Event leggero.
    /// Usato da `IndexService` per dimensionare il fetch a blocchi e mostrare
    /// un progresso reale prima ancora di leggere le proprietà dei brani.
    public func trackCount() async throws -> Int {
        let script = """
        tell application "Music"
            return (count of every track of library playlist 1)
        end tell
        """
        let raw = try runAppleScript(script)
        return Int(raw) ?? 0
    }

    /// Recupera un blocco di brani per indice 1-based inclusivo, in un solo
    /// Apple Event (tab-delimited). Usa `tracks X thru Y of library playlist 1`
    /// (Fase 0, finding F0.2) — non `items X thru Y of every track`.
    ///
    /// Fetchare a blocchi (invece che l'intera libreria in una volta, o un
    /// Apple Event per proprietà come fa ScriptingBridge) serve a:
    /// - dare un progresso reale tra un blocco e il successivo;
    /// - permettere la cancellazione cooperativa tra un blocco e il successivo;
    /// - isolare un eventuale alias/percorso irrisolvibile (es. volume esterno
    ///   scollegato) al `try ... end try` del singolo brano, senza dover
    ///   attendere o ripetere l'intera libreria.
    public func tracksChunk(from start: Int, to end: Int) async throws -> [Track] {
        // Fetch di lista: ogni `property of every item of theTracks` è UN solo
        // Apple Event che restituisce tutti i valori → 17 eventi per chunk
        // invece di 17.000 (17 proprietà × 1000 track). Speedup ~1000×.
        // Ogni `property of every item of theTracks` è UN Apple Event → 17 eventi
        // per chunk vs 17.000 del vecchio repeat-per-track. Il repeat finale opera
        // su liste locali (già scaricate), nessun Apple Event aggiuntivo.
        // I valori "missing value" vengono coercizzati ad "" in Swift dal parser.
        // `property of (tracks X thru Y of lib)` → UN solo Apple Event per proprietà.
        // NON usare `every item of rangeRef`: crea specifier list invece di liste dati.
        let script = """
        tell application "Music"
            set lib to library playlist 1
            set pids  to persistent ID of (tracks \(start) thru \(end) of lib)
            set dbids to database ID of (tracks \(start) thru \(end) of lib)
            set nms   to name of (tracks \(start) thru \(end) of lib)
            set arts  to artist of (tracks \(start) thru \(end) of lib)
            set aarts to album artist of (tracks \(start) thru \(end) of lib)
            set albs  to album of (tracks \(start) thru \(end) of lib)
            set yrs   to year of (tracks \(start) thru \(end) of lib)
            set gens  to genre of (tracks \(start) thru \(end) of lib)
            set coms  to comment of (tracks \(start) thru \(end) of lib)
            set comps to composer of (tracks \(start) thru \(end) of lib)
            set tnums to track number of (tracks \(start) thru \(end) of lib)
            set tcnts to track count of (tracks \(start) thru \(end) of lib)
            set dnums to disc number of (tracks \(start) thru \(end) of lib)
            set dcnts to disc count of (tracks \(start) thru \(end) of lib)
            set durs  to duration of (tracks \(start) thru \(end) of lib)
            set brs   to bit rate of (tracks \(start) thru \(end) of lib)
            set srs   to sample rate of (tracks \(start) thru \(end) of lib)
            set knds  to kind of (tracks \(start) thru \(end) of lib)
            set output to ""
            set n to count of pids
            repeat with i from 1 to n
                set row to (item i of pids) as string & tab & (item i of dbids) as string & tab & (item i of nms) as string & tab & (item i of arts) as string & tab & (item i of aarts) as string & tab & (item i of albs) as string & tab & (item i of yrs) as string & tab & (item i of gens) as string & tab & (item i of coms) as string & tab & (item i of comps) as string & tab & (item i of tnums) as string & tab & (item i of tcnts) as string & tab & (item i of dnums) as string & tab & (item i of dcnts) as string & tab & (item i of durs) as string & tab & (item i of brs) as string & tab & (item i of srs) as string & tab & (item i of knds) as string
                set output to output & row & return
            end repeat
        end tell
        return output
        """
        let raw = try runAppleScript(script)
        return parseTabDelimitedTracks(raw)
    }

    // ─── Scansione presenza copertina ─────────────────────────────────────────

    /// Controlla quali brani nel range 1-based [start, end] hanno almeno una
    /// copertina in Music.app. Restituisce due set: quelli CON copertina e quelli
    /// SENZA. Ogni brano richiede ~2 Apple Events (persistent ID + count of artworks);
    /// su 25k brani in chunk da 200 = ~250 secondi stimati (0.5ms/event su macOS).
    public func artworkPresenceScan(from start: Int, to end: Int) async throws -> (having: Set<String>, lacking: Set<String>) {
        let script = """
        tell application "Music"
            set lib to library playlist 1
            set output to ""
            repeat with i from \(start) to \(end)
                try
                    set t to track i of lib
                    set pid to (persistent ID of t) as string
                    if (count of artworks of t) > 0 then
                        set output to output & pid & tab & "1" & return
                    else
                        set output to output & pid & tab & "0" & return
                    end if
                end try
            end repeat
            return output
        end tell
        """
        let raw = try runAppleScript(script)
        var having = Set<String>()
        var lacking = Set<String>()
        for line in raw.components(separatedBy: "\r") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            if parts[1] == "1" { having.insert(parts[0]) } else { lacking.insert(parts[0]) }
        }
        return (having, lacking)
    }

    // ─── Risoluzione location autoritativa da Music ────────────────────────

    /// Per i `pids` indicati restituisce il path POSIX reale del file locale
    /// così come noto a Music.app — la sola fonte di verità affidabile quando
    /// l'euristica filesystem (Artist/Album/NN) fallisce (compilation, nomi
    /// sanitizzati, prefissi disco nei filename, ecc.).
    ///
    /// Strategia: scansione della libreria per indice a blocchi. Per ogni blocco
    /// un solo Apple Event recupera la lista dei `persistent ID`; la `location`
    /// viene poi risolta SOLO per gli indici i cui pid sono richiesti, ognuno
    /// isolato in `try`/`with timeout` (come `trackMetadata`) così un alias
    /// irrisolvibile non blocca il resto. I brani senza location locale (cloud/
    /// streaming reali) semplicemente non compaiono nella mappa restituita.
    public func locationsForPersistentIDs(_ pids: Set<String>) async throws -> [String: String] {
        guard !pids.isEmpty else { return [:] }
        let total = try await trackCount()
        var result: [String: String] = [:]
        let chunkSize = 1000
        var start = 1
        while start <= total {
            try Task.checkCancellation()
            let end = min(start + chunkSize - 1, total)

            // 1) Lista pid del blocco in un solo Apple Event.
            let pidScript = """
            tell application "Music"
                set lib to library playlist 1
                set output to ""
                set ps to persistent ID of (tracks \(start) thru \(end) of lib)
                repeat with p in ps
                    set output to output & (p as string) & return
                end repeat
            end tell
            return output
            """
            let pidRaw = try runAppleScript(pidScript)
            let chunkPIDs = pidRaw.components(separatedBy: "\r").filter { !$0.isEmpty }

            // 2) Indici (assoluti, 1-based) dei soli brani richiesti.
            var wantedIndices: [Int] = []
            for (offset, pid) in chunkPIDs.enumerated() where pids.contains(pid) {
                wantedIndices.append(start + offset)
            }
            if wantedIndices.isEmpty { start = end + 1; continue }

            // 3) Location per gli indici richiesti, isolata per-track.
            let idxList = wantedIndices.map(String.init).joined(separator: ", ")
            let locScript = """
            tell application "Music"
                set lib to library playlist 1
                set output to ""
                repeat with idx in {\(idxList)}
                    set tPid to ""
                    set tLoc to ""
                    try
                        set t to track idx of lib
                        set tPid to (persistent ID of t) as string
                        with timeout of 2 seconds
                            set locAlias to location of t
                            if locAlias is not missing value then
                                set tLoc to (POSIX path of locAlias) as string
                            end if
                        end timeout
                    end try
                    set output to output & tPid & tab & tLoc & return
                end repeat
            end tell
            return output
            """
            let locRaw = try runAppleScript(locScript)
            for line in locRaw.components(separatedBy: "\r") where !line.isEmpty {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { continue }
                let pid = parts[0]
                let path = parts[1]
                if !pid.isEmpty, !path.isEmpty { result[pid] = path }
            }

            start = end + 1
        }
        return result
    }

    // Parser per il fetch bulk (senza location). "missing value" viene emesso da
    // AppleScript quando un campo non ha valore — trattiamo come "" o 0.
    private func parseTabDelimitedTracks(_ raw: String) -> [Track] {
        raw.components(separatedBy: "\r")
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 18 else { return nil }
                let pid = parts[0]
                guard !pid.isEmpty, pid != "missing value" else { return nil }
                return Track(
                    persistentID: pid,
                    databaseID: Int(parts[1]) ?? 0,
                    location: nil,
                    name: mv(parts[2]),
                    artist: mv(parts[3]),
                    albumArtist: mv(parts[4]),
                    album: mv(parts[5]),
                    year: Int(mv(parts[6])) ?? 0,
                    genre: mv(parts[7]),
                    comment: mv(parts[8]),
                    composer: mv(parts[9]),
                    trackNumber: Int(mv(parts[10])) ?? 0,
                    trackCount: Int(mv(parts[11])) ?? 0,
                    discNumber: Int(mv(parts[12])) ?? 0,
                    discCount: Int(mv(parts[13])) ?? 0,
                    duration: parseLocaleDouble(mv(parts[14])),
                    bitRate: Int(mv(parts[15])) ?? 0,
                    sampleRate: parseLocaleDouble(mv(parts[16])),
                    kind: mv(parts[17])
                )
            }
    }

    /// Converte "missing value" (stringa emessa da AppleScript) in stringa vuota.
    private func mv(_ s: String) -> String { s == "missing value" ? "" : s }

    // ─── trackMetadata ──────────────────────────────────────────────────────

    public func trackMetadata(persistentID: String) async throws -> Track {
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            set tLoc to ""
            try
                with timeout of 2 seconds
                    set locAlias to location of t
                    if locAlias is not missing value then
                        set tLoc to (POSIX path of locAlias) as string
                    end if
                end timeout
            end try
            set row to (persistent ID of t) & tab & (database ID of t)
            set row to row & tab & tLoc
            set row to row & tab & (name of t)
            set row to row & tab & (artist of t)
            set row to row & tab & (album artist of t)
            set row to row & tab & (album of t)
            set row to row & tab & (year of t)
            set row to row & tab & (genre of t)
            set row to row & tab & (comment of t)
            set row to row & tab & (composer of t)
            set row to row & tab & (track number of t)
            set row to row & tab & (track count of t)
            set row to row & tab & (disc number of t)
            set row to row & tab & (disc count of t)
            set row to row & tab & (duration of t)
            set row to row & tab & (bit rate of t)
            set row to row & tab & (sample rate of t)
            set row to row & tab & (kind of t)
            return row
        end tell
        """
        let raw = try runAppleScript(script)
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 19 else {
            throw MusiFixError.trackNotFound(persistentID: persistentID)
        }
        return Track(
            persistentID: parts[0],
            databaseID: Int(parts[1]) ?? 0,
            location: parts[2].isEmpty ? nil : URL(fileURLWithPath: parts[2]),
            name: parts[3],
            artist: parts[4],
            albumArtist: parts[5],
            album: parts[6],
            year: Int(parts[7]) ?? 0,
            genre: parts[8],
            comment: parts[9],
            composer: parts[10],
            trackNumber: Int(parts[11]) ?? 0,
            trackCount: Int(parts[12]) ?? 0,
            discNumber: Int(parts[13]) ?? 0,
            discCount: Int(parts[14]) ?? 0,
            duration: parseLocaleDouble(parts[15]),
            bitRate: Int(parts[16]) ?? 0,
            sampleRate: parseLocaleDouble(parts[17]),
            kind: parts[18]
        )
    }

    // ─── updateMetadata ─────────────────────────────────────────────────────

    public func updateMetadata(_ update: TrackMetadataUpdate, persistentID: String) async throws {
        let pid = persistentID.appleScriptEscaped()
        var statements: [String] = []

        if let v = update.name        { statements.append(#"set name of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.artist      { statements.append(#"set artist of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.albumArtist { statements.append(#"set album artist of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.album       { statements.append(#"set album of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.year        { statements.append("set year of t to \(v)") }
        if let v = update.genre       { statements.append(#"set genre of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.comment     { statements.append(#"set comment of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.composer    { statements.append(#"set composer of t to "\#(v.appleScriptEscaped())""#) }
        if let v = update.trackNumber { statements.append("set track number of t to \(v)") }
        if let v = update.trackCount  { statements.append("set track count of t to \(v)") }
        if let v = update.discNumber  { statements.append("set disc number of t to \(v)") }
        if let v = update.discCount   { statements.append("set disc count of t to \(v)") }

        guard !statements.isEmpty else { return }

        let body = statements.joined(separator: "\n            ")
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            \(body)
        end tell
        """
        _ = try runAppleScript(script)
    }

    // ─── artwork ────────────────────────────────────────────────────────────

    public func setArtwork(_ data: Data, persistentID: String) async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("musifixpoc_artwork_\(persistentID).jpg")
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let path = tmpURL.path.appleScriptEscaped()
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            delete artworks of t
            set theAlias to POSIX file "\(path)"
            tell t
                make new artwork at end of artworks with properties {data:theAlias}
            end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func artwork(persistentID: String) async throws -> Data? {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("musifixpoc_artout_\(persistentID).jpg")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let path = tmpURL.path.appleScriptEscaped()
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            if (count of artworks of t) is 0 then return ""
            set aw to item 1 of artworks of t
            set rawData to raw data of aw
            set tmpFile to open for access POSIX file "\(path)" with write permission
            write rawData to tmpFile
            close access tmpFile
        end tell
        return "\(path)"
        """
        let result = try runAppleScript(script)
        guard !result.isEmpty, FileManager.default.fileExists(atPath: tmpURL.path) else {
            return nil
        }
        return try Data(contentsOf: tmpURL)
    }

    public func deleteTrack(persistentID: String) async throws {
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            delete t
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func revealInMusic(persistentID: String) async throws {
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            reveal t
            activate
        end tell
        """
        _ = try runAppleScript(script)
    }

    // ─── NSAppleScript runner ────────────────────────────────────────────────

    @discardableResult
    func runAppleScript(_ source: String) throws -> String {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MusiFixError.appleScriptError("Impossibile creare NSAppleScript")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "\(info)"
            throw MusiFixError.appleScriptError(msg)
        }
        return result.stringValue ?? ""
    }
}

// ─── Utility ──────────────────────────────────────────────────────────────────

private extension String {
    func appleScriptEscaped() -> String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Parsa un Double gestendo sia il punto che la virgola come separatore decimale.
private func parseLocaleDouble(_ s: String) -> Double {
    if let v = Double(s) { return v }
    return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
}
