import Foundation

/// Rappresentazione in-memory di un brano della libreria Music.
public struct Track: Sendable, Identifiable {
    public var id: String { persistentID }
    public let persistentID: String
    public let databaseID: Int
    public var location: URL?
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
    public let duration: Double
    public let bitRate: Int
    public let sampleRate: Double
    public let kind: String
    public let dateAdded: Date?
    public let modificationDate: Date?

    public init(
        persistentID: String,
        databaseID: Int,
        location: URL?,
        name: String,
        artist: String,
        albumArtist: String,
        album: String,
        year: Int,
        genre: String,
        comment: String = "",
        composer: String = "",
        trackNumber: Int = 0,
        trackCount: Int = 0,
        discNumber: Int = 0,
        discCount: Int = 0,
        duration: Double = 0,
        bitRate: Int = 0,
        sampleRate: Double = 0,
        kind: String = "",
        dateAdded: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.persistentID = persistentID
        self.databaseID = databaseID
        self.location = location
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
        self.kind = kind
        self.dateAdded = dateAdded
        self.modificationDate = modificationDate
    }
}

/// Campi modificabili via Apple Music automation.
public struct TrackMetadataUpdate: Sendable {
    public var name: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
    public var comment: String?
    public var composer: String?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?

    public init(
        name: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        comment: String? = nil,
        composer: String? = nil,
        trackNumber: Int? = nil,
        trackCount: Int? = nil,
        discNumber: Int? = nil,
        discCount: Int? = nil
    ) {
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
    }
}
