import Foundation
import Persistence
import GRDB

/// Gestisce le esclusioni "ignora in MusiFix": brani e album che i processi di
/// sistemazione (verifica completezza album, normalizzazione) devono saltare.
/// Persistite nelle tabelle `track_ignore` / `album_ignore` (migrazione v9).
public actor IgnoreService {

    private let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Chiave album coerente con AlbumDAO/album_store_info:
    /// LOWER(albumArtist, o artist se vuoto) + separatore unità (CHAR 31) + LOWER(album).
    public static func albumKey(albumArtist: String, artist: String, album: String) -> String {
        let head = albumArtist.isEmpty ? artist : albumArtist
        return head.lowercased() + "\u{1F}" + album.lowercased()
    }

    // ── Brani ─────────────────────────────────────────────────────────────────

    public func ignoreTracks(_ pids: [String]) throws {
        try db.write { db in
            for pid in pids { try DBTrackIgnore(persistentID: pid).upsert(db) }
        }
    }

    public func unignoreTracks(_ pids: [String]) throws {
        try db.write { db in
            for pid in pids { _ = try DBTrackIgnore.deleteOne(db, key: pid) }
        }
    }

    public func ignoredTrackPIDs() throws -> Set<String> {
        try db.read { try Set(String.fetchAll($0, sql: "SELECT persistentID FROM track_ignore")) }
    }

    // ── Album ─────────────────────────────────────────────────────────────────

    public func ignoreAlbum(key: String, albumArtist: String, album: String) throws {
        try db.write {
            try DBAlbumIgnore(albumKey: key, albumArtist: albumArtist, album: album).upsert($0)
        }
    }

    public func unignoreAlbum(key: String) throws {
        try db.write { _ = try DBAlbumIgnore.deleteOne($0, key: key) }
    }

    public func ignoredAlbumKeys() throws -> Set<String> {
        try db.read { try Set(String.fetchAll($0, sql: "SELECT albumKey FROM album_ignore")) }
    }

    // ── Vista combinata ─────────────────────────────────────────────────────────

    /// Insieme completo di PID esclusi: brani ignorati direttamente + tutti i brani
    /// che appartengono a un album ignorato.
    public func ignoredPIDsUnion() throws -> Set<String> {
        try db.read { db in
            var pids = try Set(String.fetchAll(db, sql: "SELECT persistentID FROM track_ignore"))
            let albumPids = try String.fetchAll(db, sql: """
                SELECT persistentID FROM track
                WHERE (LOWER(COALESCE(NULLIF(albumArtist,''), artist)) || CHAR(31) || LOWER(album))
                      IN (SELECT albumKey FROM album_ignore)
                """)
            pids.formUnion(albumPids)
            return pids
        }
    }
}
