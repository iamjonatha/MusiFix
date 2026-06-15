import Foundation
import Persistence
import GRDB

/// Statistiche aggregate della libreria, calcolate dal DB locale.
public struct LibraryStats: Sendable {
    public let totalTracks: Int
    // ── Campi mancanti ───────────────────────────────────────────────────────
    public let missingYear: Int
    public let missingArtist: Int
    public let missingAlbum: Int
    public let missingAlbumArtist: Int
    public let missingGenre: Int
    public let missingTrackNumber: Int
    public let missingDiscNumber: Int
    // ── Inconsistenze ────────────────────────────────────────────────────────
    public let multipleAlbumValues: Int      // brani il cui album differisce da altri brani dello stesso gruppo
    public let multipleAlbumArtistValues: Int // brani il cui albumArtist differisce da altri brani dello stesso album
    // ── Altro ────────────────────────────────────────────────────────────────
    public let cloudOnly: Int
    public let withoutFile: Int              // non cloud-only ma senza path
    public let formatBreakdown: [(format: String, count: Int)]
    public let lastSyncDate: Date?
    public let deletionCount: Int            // totale eliminazioni registrate

    public static let zero = LibraryStats(
        totalTracks: 0,
        missingYear: 0, missingArtist: 0, missingAlbum: 0,
        missingAlbumArtist: 0, missingGenre: 0,
        missingTrackNumber: 0, missingDiscNumber: 0,
        multipleAlbumValues: 0, multipleAlbumArtistValues: 0,
        cloudOnly: 0, withoutFile: 0,
        formatBreakdown: [], lastSyncDate: nil, deletionCount: 0
    )
}

/// Calcola le statistiche della libreria in una singola transazione di lettura.
public func loadLibraryStats(db: AppDatabase) throws -> LibraryStats {
    try db.read { db in
        let total           = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
        let misYear         = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE year = 0") ?? 0
        let misArtist       = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE artist = ''") ?? 0
        let misAlbum        = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE album = ''") ?? 0
        let misAlbumArtist  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE albumArtist = ''") ?? 0
        let misGenre        = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE genre = ''") ?? 0
        let misTrackNum     = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE trackNumber = 0") ?? 0
        let misDiscNum      = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE discNumber = 0") ?? 0
        let cloudOnly       = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isCloudOnly = 1") ?? 0
        let noFile          = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isCloudOnly = 0 AND locationPath IS NULL") ?? 0
        let delCount        = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deletion_log WHERE status = 'done'") ?? 0

        // Brani il cui valore del campo album è discordante rispetto ad altri brani
        // dello stesso gruppo (artistNormalized + albumNormalized).
        let multAlbum = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM track t
            WHERE t.album != '' AND EXISTS (
                SELECT 1 FROM track t2
                WHERE t2.artistNormalized = t.artistNormalized
                  AND t2.albumNormalized  = t.albumNormalized
                  AND t2.album            != t.album
                  AND t2.album            != ''
            )
            """) ?? 0

        // Brani il cui albumArtist è discordante rispetto ad altri brani dello stesso album.
        let multAlbumArtist = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM track t
            WHERE t.albumNormalized != '' AND EXISTS (
                SELECT 1 FROM track t2
                WHERE t2.albumNormalized = t.albumNormalized
                  AND t2.albumArtist    != t.albumArtist
            )
            """) ?? 0

        let fmtRows = try Row.fetchAll(db, sql: """
            SELECT format, COUNT(*) as cnt FROM track
            WHERE format != ''
            GROUP BY format ORDER BY cnt DESC LIMIT 8
            """)
        let formats = fmtRows.map { (format: $0["format"] as String, count: $0["cnt"] as Int) }

        let lastSync: Date? = try SyncStateDAO.lastMusicSyncDate(in: db)

        return LibraryStats(
            totalTracks: total,
            missingYear: misYear,
            missingArtist: misArtist,
            missingAlbum: misAlbum,
            missingAlbumArtist: misAlbumArtist,
            missingGenre: misGenre,
            missingTrackNumber: misTrackNum,
            missingDiscNumber: misDiscNum,
            multipleAlbumValues: multAlbum,
            multipleAlbumArtistValues: multAlbumArtist,
            cloudOnly: cloudOnly,
            withoutFile: noFile,
            formatBreakdown: formats,
            lastSyncDate: lastSync,
            deletionCount: delCount
        )
    }
}
