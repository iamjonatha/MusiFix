import Foundation
import GRDB

/// Accesso alle tabelle `playlist` / `playlist_track` (Fase 19).
public enum PlaylistDAO {

    /// Tutte le playlist/cartelle note (dopo una scansione playlist).
    public static func fetchPlaylists(in db: Database) throws -> [DBPlaylist] {
        try DBPlaylist
            .order(Column("name"))
            .fetchAll(db)
    }

    /// True se la scansione playlist dettagliata è stata eseguita almeno una volta.
    public static func scanDone(in db: Database) throws -> Bool {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0) > 0
    }

    /// Nomi delle playlist (non cartelle) che contengono il brano indicato.
    public static func playlistNamesForTrack(pid: String, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT p.name FROM playlist_track pt
            JOIN playlist p ON p.id = pt.playlistID
            WHERE pt.pid = ? AND p.isFolder = 0
            ORDER BY p.name COLLATE NOCASE
            """, arguments: [pid])
    }

    /// Brani contenuti in una playlist, ordinati come il browser (album/disco/traccia).
    public static func tracksInPlaylist(id: String, in db: Database) throws -> [DBTrack] {
        try DBTrack.fetchAll(db, sql: """
            SELECT t.* FROM playlist_track pt
            JOIN track t ON t.persistentID = pt.pid
            WHERE pt.playlistID = ?
            ORDER BY t.albumNormalized, t.discNumber, t.trackNumber, t.name
            """, arguments: [id])
    }

    /// Numero di brani in una playlist (conteggio veloce, senza join sui metadati).
    public static func trackCount(id: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_track WHERE playlistID = ?",
                         arguments: [id]) ?? 0
    }

    /// Sostituisce integralmente le tabelle playlist con lo snapshot fornito.
    /// `members` è la lista (playlistID, pid) da inserire.
    public static func replaceAll(
        playlists: [DBPlaylist],
        members: [(playlistID: String, pid: String)],
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM playlist_track")
        try db.execute(sql: "DELETE FROM playlist")
        for pl in playlists { try pl.insert(db) }
        for m in members {
            try db.execute(sql: "INSERT OR IGNORE INTO playlist_track (playlistID, pid) VALUES (?, ?)",
                           arguments: [m.playlistID, m.pid])
        }
    }
}
