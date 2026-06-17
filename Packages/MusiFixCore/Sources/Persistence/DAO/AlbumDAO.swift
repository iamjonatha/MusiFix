import GRDB
import Foundation

/// Stato di completezza di un album, valutato offline sui tag embeddati.
public enum AlbumCompleteness: String, Sendable {
    case complete      // brani presenti == trackCount tag
    case incomplete    // brani presenti < trackCount tag
    case excess        // brani presenti > trackCount tag (possibili duplicati/edizioni)
    case unknown       // tag trackCount assente → richiede verifica online (Fase D)
    case multiDisc     // album multi-disco: confronto offline non affidabile (Fase 1 escluso)
}

/// Aggregato di un album (raggruppamento per albumArtist+album, normalizzato).
public struct AlbumGroup: Sendable, Identifiable {
    public var id: String { key }
    public let key: String            // chiave di raggruppamento (lower artist + album)
    public let albumArtist: String    // valore di display
    public let album: String          // valore di display
    public let actualCount: Int       // brani effettivamente presenti
    public let tagTrackCount: Int     // MAX(trackCount) dai tag — 0 = assente
    public let tagDiscCount: Int      // MAX(discCount) dai tag
    public let cloudOnlyCount: Int    // quante tracce senza file locale
    public let pids: [String]
    /// Conteggio tracce per codice cloudStatus (es. ["kMat": 8, "kUpl": 2]).
    public let cloudStatusCounts: [String: Int]

    /// True se le tracce non hanno tutte lo stesso stato iCloud (Fase F).
    public var hasMixedCloudStatus: Bool {
        cloudStatusCounts.values.filter { $0 > 0 }.count > 1
    }

    public var completeness: AlbumCompleteness {
        if tagDiscCount > 1 { return .multiDisc }
        if tagTrackCount <= 0 { return .unknown }
        if actualCount == tagTrackCount { return .complete }
        return actualCount < tagTrackCount ? .incomplete : .excess
    }

    public init(
        key: String, albumArtist: String, album: String,
        actualCount: Int, tagTrackCount: Int, tagDiscCount: Int,
        cloudOnlyCount: Int, pids: [String], cloudStatusCounts: [String: Int]
    ) {
        self.key = key; self.albumArtist = albumArtist; self.album = album
        self.actualCount = actualCount; self.tagTrackCount = tagTrackCount
        self.tagDiscCount = tagDiscCount; self.cloudOnlyCount = cloudOnlyCount
        self.pids = pids; self.cloudStatusCounts = cloudStatusCounts
    }
}

/// Query di aggregazione a livello di album.
public struct AlbumDAO: Sendable {

    /// Raggruppa le tracce per album (albumArtist+album normalizzati),
    /// escludendo album vuoti e singoli (`album LIKE '% - Single'`).
    public static func fetchAlbumGroups(in db: Database) throws -> [AlbumGroup] {
        let sql = """
            SELECT
                MIN(COALESCE(NULLIF(albumArtist,''), artist)) AS dispArtist,
                MIN(album) AS dispAlbum,
                LOWER(COALESCE(NULLIF(albumArtist,''), artist)) || CHAR(31) || LOWER(album) AS gkey,
                COUNT(*) AS actualCount,
                MAX(trackCount) AS tagTrackCount,
                MAX(discCount) AS tagDiscCount,
                SUM(isCloudOnly) AS cloudOnlyCount,
                GROUP_CONCAT(persistentID, ',') AS pids,
                GROUP_CONCAT(cloudStatus, ',') AS cloudStatuses
            FROM track
            WHERE TRIM(album) != '' AND album NOT LIKE '% - Single'
            GROUP BY gkey
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let pidString: String = row["pids"] ?? ""
            let statusString: String = row["cloudStatuses"] ?? ""
            var counts: [String: Int] = [:]
            for code in statusString.components(separatedBy: ",") {
                counts[code, default: 0] += 1
            }
            return AlbumGroup(
                key: row["gkey"],
                albumArtist: row["dispArtist"] ?? "",
                album: row["dispAlbum"] ?? "",
                actualCount: row["actualCount"] ?? 0,
                tagTrackCount: row["tagTrackCount"] ?? 0,
                tagDiscCount: row["tagDiscCount"] ?? 0,
                cloudOnlyCount: row["cloudOnlyCount"] ?? 0,
                pids: pidString.isEmpty ? [] : pidString.components(separatedBy: ","),
                cloudStatusCounts: counts
            )
        }
    }
}
