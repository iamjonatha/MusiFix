import Foundation

/// Implementazione fallback via NSAppleScript.
/// Usata quando ScriptingBridge non è disponibile (regressioni macOS / sandbox).
public final class NSAppleScriptImpl: AppleMusicBridge, @unchecked Sendable {

    public init() {}

    // ─── allTracks ──────────────────────────────────────────────────────────

    public func allTracks() async throws -> [Track] {
        // Legge tutte le proprietà in blocchi separati (un Apple Event per proprietà)
        // per evitare la lentezza dei record AppleScript e i problemi di escape.
        // Usiamo "tab" e "return" che sono costanti AppleScript native.
        let script = """
        tell application "Music"
            set lib to library playlist 1
            set output to ""
            set theTracks to every track of lib
            repeat with t in theTracks
                set tLoc to ""
                try
                    set locAlias to location of t
                    if locAlias is not missing value then
                        set tLoc to (POSIX path of locAlias) as string
                    end if
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
                set output to output & row & return
            end repeat
        end tell
        return output
        """
        let raw = try runAppleScript(script)
        return parseTabDelimitedTracks(raw)
    }

    // Parser: AppleScript usa `return` (CR, \r) come separatore di riga
    // e `tab` (\t) come separatore di campo. I numeri decimali usano il
    // separatore del locale sistema (virgola in italiano) — normalizziamo.
    private func parseTabDelimitedTracks(_ raw: String) -> [Track] {
        raw.components(separatedBy: "\r")
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 19 else { return nil }
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
    }

    // ─── trackMetadata ──────────────────────────────────────────────────────

    public func trackMetadata(persistentID: String) async throws -> Track {
        let pid = persistentID.appleScriptEscaped()
        let script = """
        tell application "Music"
            set t to (first track of library playlist 1 whose persistent ID is "\(pid)")
            set tLoc to ""
            try
                set locAlias to location of t
                if locAlias is not missing value then
                    set tLoc to (POSIX path of locAlias) as string
                end if
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
