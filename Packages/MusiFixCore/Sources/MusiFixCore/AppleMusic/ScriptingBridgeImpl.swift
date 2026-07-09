import Foundation
import MusicBridge

// SBApplication non è thread-safe: accessi concorrenti corrompono lo stato interno
// del proxy ObjC causando hang indefiniti. Questo actor serializza tutte le chiamate
// al bridge ObjC garantendo un solo accesso alla volta.
private actor BridgeSerializer {
    private let bridge: MusicBridgeObjC
    init(_ bridge: MusicBridgeObjC) { self.bridge = bridge }

    func artworkData(pid: String) throws -> Data? {
        try bridge.artworkData(forPersistentID: pid)
    }
    func setArtworkData(_ data: Data, pid: String) throws {
        try bridge.setArtworkData(data, forPersistentID: pid)
    }
}

/// Implementazione primaria via ScriptingBridge (ObjC wrapper MusicBridgeObjC).
/// Restituisce nil se Music.app non è raggiungibile al momento dell'init.
public final class ScriptingBridgeImpl: AppleMusicBridge, @unchecked Sendable {
    private let bridge: MusicBridgeObjC
    private let serializer: BridgeSerializer

    public init?() {
        guard let b = MusicBridgeObjC.sharedBridge() else { return nil }
        self.bridge = b
        self.serializer = BridgeSerializer(b)
    }

    // Swift converte automaticamente i metodi ObjC con NSError** in funzioni throws.
    // Non passare l'argomento error: — il compilatore genera il binding corretto.

    public func allTracks() async throws -> [Track] {
        let raw = try bridge.allTracks() as? [[String: Any]] ?? []
        return try raw.map { try Track(from: $0) }
    }

    public func trackMetadata(persistentID: String) async throws -> Track {
        do {
            let raw = try bridge.trackMetadata(forPersistentID: persistentID)
            return try Track(from: raw as? [String: Any] ?? [:])
        } catch {
            // ScriptingBridge può lanciare su track cloud-only (enumCodeValue su NSString);
            // fallback via AppleScript che gestisce correttamente tutti i tipi di traccia.
            return try await NSAppleScriptImpl().trackMetadata(persistentID: persistentID)
        }
    }

    public func updateMetadata(_ update: TrackMetadataUpdate, persistentID: String) async throws {
        let dict = update.toObjCDict()
        try bridge.setMetadata(dict, forPersistentID: persistentID)
    }

    public func setArtwork(_ data: Data, persistentID: String) async throws {
        do {
            try await serializer.setArtworkData(data, pid: persistentID)
        } catch {
            // Come trackMetadata: su brani cloud/matched ScriptingBridge può fallire
            // silenziosamente nella scrittura dell'artwork; fallback via AppleScript.
            try await NSAppleScriptImpl().setArtwork(data, persistentID: persistentID)
        }
    }

    public func artwork(persistentID: String) async throws -> Data? {
        if let data = try? await serializer.artworkData(pid: persistentID) {
            return data
        }
        // ScriptingBridge può restituire nil su brani cloud/matched pur essendoci
        // una copertina valida (vedi MusicBridgeObjC.m); fallback via AppleScript.
        return try await NSAppleScriptImpl().artwork(persistentID: persistentID)
    }

    public func deleteTrack(persistentID: String) async throws {
        try bridge.deleteTrack(forPersistentID: persistentID)
    }

    public func revealInMusic(persistentID: String) async throws {
        // ScriptingBridge non invia un vero "whose clause" per filteredArrayUsingPredicate:
        // — enumera tutti i brani in-process e il riferimento risultante non è valido per
        // il comando reveal. Si usa NSAppleScript che invia il corretto Apple Event direttamente.
        try await NSAppleScriptImpl().revealInMusic(persistentID: persistentID)
    }

    public func tracksInRegularPlaylists() async throws -> Set<String> {
        let raw = try bridge.regularPlaylistTrackPersistentIDs()
        return Set(raw)
    }

    public func userPlaylistTree() async throws -> [MusicPlaylistNode] {
        let raw = try bridge.userPlaylistTree() as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty else { return nil }
            return MusicPlaylistNode(
                id: id,
                name: (d["name"] as? String) ?? "",
                isFolder: (d["isFolder"] as? Bool) ?? false,
                parentID: d["parentID"] as? String   // NSNull → nil
            )
        }
    }

    public func addTracks(_ pids: [String], toPlaylistID playlistID: String) async throws -> PlaylistAddResult {
        let raw = try bridge.addTracks(withPersistentIDs: pids, toPlaylistWithPersistentID: playlistID)
        let dict = raw as? [String: Any] ?? [:]
        return PlaylistAddResult(
            added: (dict["added"] as? Int) ?? 0,
            skipped: (dict["skipped"] as? Int) ?? 0,
            failed: (dict["failed"] as? Int) ?? 0
        )
    }

    public func removeTracks(_ pids: [String], fromPlaylistID playlistID: String) async throws -> PlaylistRemoveResult {
        let raw = try bridge.removeTracks(withPersistentIDs: pids, fromPlaylistWithPersistentID: playlistID)
        let dict = raw as? [String: Any] ?? [:]
        return PlaylistRemoveResult(
            removed: (dict["removed"] as? Int) ?? 0,
            missing: (dict["missing"] as? Int) ?? 0,
            failed: (dict["failed"] as? Int) ?? 0
        )
    }

    // Creazione playlist e membership completa: via NSAppleScript, che gestisce
    // in modo affidabile `make new … at folder` e l'enumerazione con parent.
    public func ensurePlaylist(named name: String, inFolder folder: String?) async throws -> String {
        try await NSAppleScriptImpl().ensurePlaylist(named: name, inFolder: folder)
    }

    public func playlistMembership() async throws -> [PlaylistMembership] {
        try await NSAppleScriptImpl().playlistMembership()
    }
}

// ─── Track init from ObjC dict ────────────────────────────────────────────────

extension Track {
    init(from d: [String: Any]) throws {
        guard let pid = d[MBKeyPersistentID] as? String else {
            throw MusiFixError.unexpectedNilValue(context: "persistentID mancante nel dict ObjC")
        }
        let locationPath = d[MBKeyLocation] as? String
        self.init(
            persistentID: pid,
            databaseID: (d[MBKeyDatabaseID] as? Int) ?? 0,
            location: locationPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            name: (d[MBKeyName] as? String) ?? "",
            artist: (d[MBKeyArtist] as? String) ?? "",
            albumArtist: (d[MBKeyAlbumArtist] as? String) ?? "",
            album: (d[MBKeyAlbum] as? String) ?? "",
            year: (d[MBKeyYear] as? Int) ?? 0,
            genre: (d[MBKeyGenre] as? String) ?? "",
            comment: (d[MBKeyComment] as? String) ?? "",
            composer: (d[MBKeyComposer] as? String) ?? "",
            trackNumber: (d[MBKeyTrackNumber] as? Int) ?? 0,
            trackCount: (d[MBKeyTrackCount] as? Int) ?? 0,
            discNumber: (d[MBKeyDiscNumber] as? Int) ?? 0,
            discCount: (d[MBKeyDiscCount] as? Int) ?? 0,
            duration: (d[MBKeyDuration] as? Double) ?? 0,
            bitRate: (d[MBKeyBitRate] as? Int) ?? 0,
            sampleRate: (d[MBKeySampleRate] as? Double) ?? 0,
            kind: (d[MBKeyKind] as? String) ?? "",
            cloudStatus: (d[MBKeyCloudStatus] as? String) ?? "",
            dateAdded: d[MBKeyDateAdded] as? Date,
            modificationDate: d[MBKeyModDate] as? Date,
            playedCount: (d[MBKeyPlayedCount] as? Int) ?? 0,
            playedDate: d[MBKeyPlayedDate] as? Date
        )
    }
}

// ─── TrackMetadataUpdate → ObjC dict ──────────────────────────────────────────

extension TrackMetadataUpdate {
    func toObjCDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = name        { d[MBKeyName]        = v }
        if let v = artist      { d[MBKeyArtist]      = v }
        if let v = albumArtist { d[MBKeyAlbumArtist] = v }
        if let v = album       { d[MBKeyAlbum]       = v }
        if let v = year        { d[MBKeyYear]        = v }
        if let v = genre       { d[MBKeyGenre]       = v }
        if let v = comment     { d[MBKeyComment]     = v }
        if let v = composer    { d[MBKeyComposer]    = v }
        if let v = trackNumber { d[MBKeyTrackNumber] = v }
        if let v = trackCount  { d[MBKeyTrackCount]  = v }
        if let v = discNumber  { d[MBKeyDiscNumber]  = v }
        if let v = discCount   { d[MBKeyDiscCount]   = v }
        return d
    }
}
