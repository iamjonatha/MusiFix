import GRDB
import Foundation

/// Riga della tabella `track` nel database SQLite.
/// È la proiezione dell'indice — la source of truth rimane Apple Music.
public struct DBTrack: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "track"

    public var persistentID: String
    public var databaseID: Int
    public var locationPath: String?       // nil = cloud-only
    public var locationMtime: Double?      // mtime del file (secondi Unix)
    public var locationSize: Int64?        // dimensione file in byte
    public var contentHash: String?        // SHA256 troncato ai primi 16 byte (hex)
    public var isCloudOnly: Bool
    public var isEditable: Bool            // false se cloud-only senza file locale

    public var name: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var year: Int
    public var genre: String
    public var comment: String
    public var composer: String
    public var trackNumber: Int
    public var trackCount: Int
    public var discNumber: Int
    public var discCount: Int

    public var duration: Double
    public var bitRate: Int
    public var sampleRate: Double
    public var format: String              // "m4a", "mp3", ecc. (dal path)
    public var kind: String               // descrizione Music.app

    public var musicDateAdded: Date?
    public var musicModDate: Date?         // modificationDate da Music
    public var indexedAt: Date            // quando è stato indicizzato/aggiornato

    // Normalizzati per clustering fuzzy (generati da NormalizationService)
    public var artistNormalized: String
    public var albumNormalized: String
    public var genreNormalized: String

    // Fingerprint audio per dedup contenuto (Fase 4)
    public var audioFingerprint: Data?

    public init(
        persistentID: String,
        databaseID: Int,
        locationPath: String?,
        locationMtime: Double?,
        locationSize: Int64?,
        contentHash: String?,
        isCloudOnly: Bool,
        isEditable: Bool,
        name: String,
        artist: String,
        albumArtist: String,
        album: String,
        year: Int,
        genre: String,
        comment: String,
        composer: String,
        trackNumber: Int,
        trackCount: Int,
        discNumber: Int,
        discCount: Int,
        duration: Double,
        bitRate: Int,
        sampleRate: Double,
        format: String,
        kind: String,
        musicDateAdded: Date?,
        musicModDate: Date?,
        indexedAt: Date
    ) {
        self.persistentID = persistentID
        self.databaseID = databaseID
        self.locationPath = locationPath
        self.locationMtime = locationMtime
        self.locationSize = locationSize
        self.contentHash = contentHash
        self.isCloudOnly = isCloudOnly
        self.isEditable = isEditable
        self.name = name
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.genre = genre
        self.comment = comment
        self.composer = composer
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.duration = duration
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.format = format
        self.kind = kind
        self.musicDateAdded = musicDateAdded
        self.musicModDate = musicModDate
        self.indexedAt = indexedAt
        self.artistNormalized = artist.lowercased()
        self.albumNormalized = album.lowercased()
        self.genreNormalized = genre.lowercased()
        self.audioFingerprint = nil
    }
}

public struct DBAliasRule: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "genre_alias"
    public var from: String
    public var to: String
}

public struct DBArtistAlias: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "artist_alias"
    public var from: String
    public var to: String
}

public struct DBDuplicateIgnore: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "duplicate_ignore"
    public var pid1: String
    public var pid2: String
    public var ignoredAt: Date

    public init(pid1: String, pid2: String, ignoredAt: Date = Date()) {
        self.pid1 = pid1; self.pid2 = pid2; self.ignoredAt = ignoredAt
    }
}

public struct DBOperation: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "operation_log"
    public var id: Int64?
    public var persistentID: String
    public var field: String
    public var valueBefore: String?
    public var valueAfter: String?
    public var performedAt: Date
    public var status: String             // "pending" | "done" | "failed" | "undone"
    public var errorMessage: String?
    public var batchID: String?           // raggruppa le operazioni di una stessa scrittura

    public init(id: Int64? = nil, persistentID: String, field: String,
                valueBefore: String?, valueAfter: String?, performedAt: Date,
                status: String = "pending", errorMessage: String? = nil, batchID: String? = nil) {
        self.id = id; self.persistentID = persistentID; self.field = field
        self.valueBefore = valueBefore; self.valueAfter = valueAfter
        self.performedAt = performedAt; self.status = status
        self.errorMessage = errorMessage; self.batchID = batchID
    }
}

public struct DBEnrichmentCache: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "enrichment_cache"
    public var cacheKey: String           // es. "itunes:\(artist):\(album)"
    public var provider: String
    public var artworkURL: String?
    public var artworkData: Data?
    public var releaseYear: Int?
    public var fetchedAt: Date
    public var score: Double
}

/// Stato di avanzamento di un'indicizzazione in corso (per ripresa dopo interruzione).
public struct DBIndexingCheckpoint: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "indexing_checkpoint"
    public var id: Int64?
    public var startedAt: Date
    public var lastPersistentID: String?  // ultimo ID processato
    public var totalExpected: Int
    public var processed: Int
    public var phase: String              // "music_fetch" | "file_enrich" | "fts_rebuild"
    public var completedAt: Date?
}

/// Audit trail delle eliminazioni (persiste anche dopo che il track è rimosso dall'indice).
public struct DBDeletionLog: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "deletion_log"
    public var id: Int64?
    public var persistentID: String
    public var name: String
    public var artist: String
    public var album: String
    public var locationPath: String?
    public var scope: String           // "music_only" | "music_and_trash"
    public var deletedAt: Date
    public var status: String          // "done" | "failed"
    public var errorMessage: String?
    public var batchID: String?

    public init(
        id: Int64? = nil,
        persistentID: String,
        name: String,
        artist: String,
        album: String,
        locationPath: String?,
        scope: String,
        deletedAt: Date = Date(),
        status: String = "done",
        errorMessage: String? = nil,
        batchID: String? = nil
    ) {
        self.id = id; self.persistentID = persistentID; self.name = name
        self.artist = artist; self.album = album; self.locationPath = locationPath
        self.scope = scope; self.deletedAt = deletedAt; self.status = status
        self.errorMessage = errorMessage; self.batchID = batchID
    }
}

/// Stato sync FSEvents: event ID persistito per delta senza riscansione completa.
public struct DBSyncState: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sync_state"
    public var key: String                // "fsevents_last_event_id" | "last_music_sync"
    public var value: String
    public var updatedAt: Date
}
