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

    /// Brani contenuti in una playlist, nell'ordine della playlist in Music.app.
    public static func tracksInPlaylist(id: String, in db: Database) throws -> [DBTrack] {
        try DBTrack.fetchAll(db, sql: """
            SELECT t.* FROM playlist_track pt
            JOIN track t ON t.persistentID = pt.pid
            WHERE pt.playlistID = ?
            ORDER BY pt.position
            """, arguments: [id])
    }

    /// Numero di brani in una playlist (conteggio veloce, senza join sui metadati).
    public static func trackCount(id: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_track WHERE playlistID = ?",
                         arguments: [id]) ?? 0
    }

    /// Candidati per l'integrazione di una playlist: brani della libreria non già
    /// presenti, affini per genere (uno dei `genres` indicati). Ordinati per numero
    /// di riproduzioni e anno, così da proporre prima i brani più significativi.
    /// Se `genres` è vuoto ricade su tutta la libreria (esclusi i già presenti).
    public static func candidateTracks(
        forPlaylistID playlistID: String, genres: [String], limit: Int, in db: Database
    ) throws -> [DBTrack] {
        let notInPlaylist = "t.persistentID NOT IN (SELECT pid FROM playlist_track WHERE playlistID = ?)"
        var sql = "SELECT t.* FROM track t WHERE \(notInPlaylist)"
        var args: [DatabaseValueConvertible] = [playlistID]
        let cleanGenres = genres.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !cleanGenres.isEmpty {
            let ph = cleanGenres.map { _ in "?" }.joined(separator: ", ")
            sql += " AND t.genre IN (\(ph))"
            args.append(contentsOf: cleanGenres)
        }
        sql += " ORDER BY t.playedCount DESC, t.year DESC LIMIT ?"
        args.append(limit)
        return try DBTrack.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    // ── Annotazioni utente (descrizione + risultato desiderato) ──────────────

    /// Annotazione utente di una playlist, se presente.
    public static func annotation(playlistID: String, in db: Database) throws -> DBPlaylistAnnotation? {
        try DBPlaylistAnnotation.fetchOne(db, key: playlistID)
    }

    /// Inserisce o aggiorna l'annotazione utente di una playlist.
    public static func upsertAnnotation(
        playlistID: String, description: String, desiredResult: String, in db: Database
    ) throws {
        try DBPlaylistAnnotation(
            playlistID: playlistID,
            playlistDescription: description,
            desiredResult: desiredResult,
            updatedAt: Date()
        ).save(db)
    }

    /// Sostituisce integralmente le tabelle playlist con lo snapshot fornito.
    /// `members` è la lista (playlistID, pid) da inserire, nell'ordine della playlist.
    public static func replaceAll(
        playlists: [DBPlaylist],
        members: [(playlistID: String, pid: String)],
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM playlist_track")
        try db.execute(sql: "DELETE FROM playlist")
        for pl in playlists { try pl.insert(db) }
        var positions: [String: Int] = [:]
        for m in members {
            let position = positions[m.playlistID, default: 0]
            positions[m.playlistID] = position + 1
            try db.execute(sql: """
                INSERT OR IGNORE INTO playlist_track (playlistID, pid, position) VALUES (?, ?, ?)
                """, arguments: [m.playlistID, m.pid, position])
        }
    }
}
