import GRDB
import Foundation

/// Operazioni CRUD e query sulla tabella `track`.
public struct TrackDAO: Sendable {

    // ── Insert / Upsert ───────────────────────────────────────────────────────

    /// Inserisce o aggiorna un brano. Usa INSERT OR REPLACE per semplicità.
    public static func upsert(_ track: DBTrack, in db: Database) throws {
        try track.upsert(db)
    }

    public static func upsertMany(_ tracks: [DBTrack], in db: Database) throws {
        for track in tracks {
            try track.upsert(db)
        }
    }

    // ── Fetch ─────────────────────────────────────────────────────────────────

    public static func fetchAll(in db: Database) throws -> [DBTrack] {
        try DBTrack.fetchAll(db)
    }

    public static func fetch(persistentID: String, in db: Database) throws -> DBTrack? {
        try DBTrack.fetchOne(db, key: persistentID)
    }

    public static func count(in db: Database) throws -> Int {
        try DBTrack.fetchCount(db)
    }

    // ── Paginazione per la tabella UI ─────────────────────────────────────────

    public static func fetchPage(
        offset: Int,
        limit: Int,
        orderBy: TrackSortField = .artist,
        ascending: Bool = true,
        filter: TrackFilter = .none,
        in db: Database
    ) throws -> [DBTrack] {
        var request = DBTrack.all()
        request = applyFilter(filter, to: request)
        request = applySorting(orderBy, ascending: ascending, to: request)
        return try request.limit(limit, offset: offset).fetchAll(db)
    }

    public static func countFiltered(filter: TrackFilter = .none, in db: Database) throws -> Int {
        var request = DBTrack.all()
        request = applyFilter(filter, to: request)
        return try request.fetchCount(db)
    }

    // ── Ricerca FTS5 ──────────────────────────────────────────────────────────

    public static func search(
        query: String,
        offset: Int = 0,
        limit: Int = 200,
        in db: Database
    ) throws -> [DBTrack] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return try fetchPage(offset: offset, limit: limit, in: db)
        }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: q) else {
            return []
        }
        let sql = """
            SELECT track.* FROM track
            INNER JOIN track_fts ON track.rowid = track_fts.rowid
            WHERE track_fts MATCH ?
            ORDER BY rank
            LIMIT ? OFFSET ?
            """
        return try DBTrack.fetchAll(db, sql: sql, arguments: [pattern, limit, offset])
    }

    // ── Modifica singolo campo ─────────────────────────────────────────────────

    public static func updateField(
        persistentID: String,
        column: String,
        value: DatabaseValue,
        indexedAt: Date = Date(),
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE track SET \(column) = ?, indexedAt = ? WHERE persistentID = ?",
            arguments: [value, indexedAt, persistentID]
        )
    }

    // ── Persistent IDs per sync ────────────────────────────────────────────────

    /// Restituisce un dizionario persistentID → musicModDate per confronto rapido.
    public static func fetchModDates(in db: Database) throws -> [String: Date?] {
        let rows = try Row.fetchAll(db, sql: "SELECT persistentID, musicModDate FROM track")
        var result = [String: Date?](minimumCapacity: rows.count)
        for row in rows {
            result[row["persistentID"]] = row["musicModDate"]
        }
        return result
    }

    public static func delete(persistentID: String, in db: Database) throws {
        try DBTrack.deleteOne(db, key: persistentID)
    }

    public static func deleteAll(in db: Database) throws {
        try DBTrack.deleteAll(db)
    }

    // ── Helpers privati ───────────────────────────────────────────────────────

    private static func applyFilter(
        _ filter: TrackFilter,
        to request: QueryInterfaceRequest<DBTrack>
    ) -> QueryInterfaceRequest<DBTrack> {
        switch filter {
        case .none:
            return request
        case .missingArtwork:
            return request.filter(Column("hasArtwork") == 0)
        case .missingYear:
            return request.filter(Column("year") == 0)
        case .missingArtist:
            return request.filter(Column("artist") == "")
        case .missingAlbum:
            return request.filter(Column("album") == "")
        case .missingAlbumArtist:
            return request.filter(Column("albumArtist") == "")
        case .missingGenre:
            return request.filter(Column("genre") == "")
        case .missingTrackNumber:
            return request.filter(Column("trackNumber") == 0)
        case .missingDiscNumber:
            return request.filter(Column("discNumber") == 0)
        case .multipleAlbumValues:
            return request.filter(sql: """
                album != '' AND EXISTS (
                    SELECT 1 FROM track t2
                    WHERE t2.artistNormalized = track.artistNormalized
                      AND t2.albumNormalized  = track.albumNormalized
                      AND t2.album            != track.album
                      AND t2.album            != ''
                )
                """)
        case .multipleAlbumArtistValues:
            return request.filter(sql: """
                albumNormalized != '' AND EXISTS (
                    SELECT 1 FROM track t2
                    WHERE t2.albumNormalized = track.albumNormalized
                      AND t2.albumArtist    != track.albumArtist
                )
                """)
        case .cloudOnly:
            return request.filter(Column("isCloudOnly") == true)
        case .localOnly:
            return request.filter(Column("isCloudOnly") == false)
        case .cloudStatus(let code):
            return request.filter(Column("cloudStatus") == code)
        case .genre(let g):
            return request.filter(Column("genreNormalized") == g.lowercased())
        case .artist(let a):
            return request.filter(Column("artistNormalized") == a.lowercased())
        case .album(let a):
            return request.filter(Column("albumNormalized") == a.lowercased())
        case .year(let y):
            return request.filter(Column("year") == y)
        case .addedYear(let y):
            return request.filter(sql: "CAST(strftime('%Y', musicDateAdded) AS INTEGER) = ?",
                                  arguments: [y])
        }
    }

    public static func fetchDistinctGenres(in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT genre FROM track
            WHERE genre != '' ORDER BY genre COLLATE NOCASE
            """)
    }

    public static func fetchDistinctAddedYears(in db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            SELECT DISTINCT CAST(strftime('%Y', musicDateAdded) AS INTEGER) yr
            FROM track WHERE musicDateAdded IS NOT NULL ORDER BY yr DESC
            """)
    }

    private static func applySorting(
        _ field: TrackSortField,
        ascending: Bool,
        to request: QueryInterfaceRequest<DBTrack>
    ) -> QueryInterfaceRequest<DBTrack> {
        let col: Column
        switch field {
        case .name:        col = Column("name")
        case .artist:      col = Column("artistNormalized")
        case .albumArtist: col = Column("albumArtist")
        case .album:       col = Column("albumNormalized")
        case .year:        col = Column("year")
        case .genre:       col = Column("genreNormalized")
        case .duration:    col = Column("duration")
        case .dateAdded:   col = Column("musicDateAdded")
        }
        let secondary = [Column("albumNormalized"), Column("discNumber"), Column("trackNumber")]
        let sorted = ascending ? request.order([col.asc] + secondary.map { $0.asc })
                               : request.order([col.desc] + secondary.map { $0.asc })
        return sorted
    }
}

// ── Tipi di supporto ─────────────────────────────────────────────────────────

public enum TrackSortField: String, Sendable, CaseIterable {
    case name, artist, albumArtist, album, year, genre, duration, dateAdded
}

public enum TrackFilter: Sendable, Equatable {
    case none
    case missingArtwork
    case missingYear
    case missingArtist
    case missingAlbum
    case missingAlbumArtist
    case missingGenre
    case missingTrackNumber
    case missingDiscNumber
    case multipleAlbumValues
    case multipleAlbumArtistValues
    case cloudOnly
    case localOnly
    case cloudStatus(String)
    case genre(String)
    case artist(String)
    case album(String)
    case year(Int)
    case addedYear(Int)          // anno di aggiunta a Music.app
}

// ── FTS5 search ──────────────────────────────────────────────────────────────

extension DBTrack {
    /// Ricerca FTS5 tramite SQL diretto (content FTS table).
    static func ftsSearch(_ pattern: FTS5Pattern, in db: Database) throws -> [DBTrack] {
        // Recupera i rowid dalla tabella FTS, poi join con track
        let sql = """
            SELECT track.* FROM track
            INNER JOIN track_fts ON track.rowid = track_fts.rowid
            WHERE track_fts MATCH ?
            ORDER BY rank
            """
        return try DBTrack.fetchAll(db, sql: sql, arguments: [pattern])
    }
}
