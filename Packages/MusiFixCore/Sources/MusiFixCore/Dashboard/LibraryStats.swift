import Foundation
import Persistence
import GRDB

/// Statistiche aggregate della libreria, calcolate dal DB locale.
public struct LibraryStats: Sendable {
    public let totalTracks: Int
    public let missingYear: Int
    public let missingArtist: Int
    public let missingAlbum: Int
    public let missingGenre: Int
    public let cloudOnly: Int
    public let withoutFile: Int       // non cloud-only ma senza path
    public let formatBreakdown: [(format: String, count: Int)]
    public let lastSyncDate: Date?
    public let deletionCount: Int     // totale eliminazioni registrate

    public static let zero = LibraryStats(
        totalTracks: 0, missingYear: 0, missingArtist: 0,
        missingAlbum: 0, missingGenre: 0, cloudOnly: 0, withoutFile: 0,
        formatBreakdown: [], lastSyncDate: nil, deletionCount: 0
    )
}

/// Calcola le statistiche della libreria in una singola transazione di lettura.
public func loadLibraryStats(db: AppDatabase) throws -> LibraryStats {
    try db.read { db in
        let total       = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
        let misYear     = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE year = 0") ?? 0
        let misArtist   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE artist = ''") ?? 0
        let misAlbum    = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE album = ''") ?? 0
        let misGenre    = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE genre = ''") ?? 0
        let cloudOnly   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isCloudOnly = 1") ?? 0
        let noFile      = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isCloudOnly = 0 AND locationPath IS NULL") ?? 0
        let delCount    = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deletion_log WHERE status = 'done'") ?? 0

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
            missingGenre: misGenre,
            cloudOnly: cloudOnly,
            withoutFile: noFile,
            formatBreakdown: formats,
            lastSyncDate: lastSync,
            deletionCount: delCount
        )
    }
}
