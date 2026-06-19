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
    public let cloudStatus: String      // codice 4-char Music.app: kMat/kUpl/kPur/kSub/…
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
        cloudStatus: String = "",
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
        self.cloudStatus = cloudStatus
        self.dateAdded = dateAdded
        self.modificationDate = modificationDate
    }
}

/// Stato iCloud di una traccia, indipendente dalla localizzazione di Music.app.
/// Mappa i codici 4-char esposti dal bridge in valori semantici.
public enum CloudStatus: String, Sendable {
    case none, purchased, matched, uploaded, subscription
    case ineligible, removed, error, duplicate, noLongerAvailable, notUploaded
    case unknown

    public init(code: String) {
        switch code {
        case "kPur": self = .purchased
        case "kMat": self = .matched
        case "kUpl": self = .uploaded
        case "kSub": self = .subscription
        case "kIne": self = .ineligible
        case "kRem": self = .removed
        case "kErr": self = .error
        case "kDpl": self = .duplicate
        case "kRdy": self = .noLongerAvailable
        case "kNot": self = .notUploaded
        case "", "kUnk": self = code.isEmpty ? .none : .unknown
        default: self = .unknown
        }
    }

    /// Etichetta in italiano per la UI.
    public var label: String {
        switch self {
        case .none:              return "Locale"
        case .purchased:         return "Acquistato"
        case .matched:           return "Abbinato"
        case .uploaded:          return "Caricato"
        case .subscription:      return "Apple Music"
        case .ineligible:        return "Non idoneo"
        case .removed:           return "Rimosso"
        case .error:             return "Errore"
        case .duplicate:         return "Duplicato"
        case .noLongerAvailable: return "Non più disponibile"
        case .notUploaded:       return "Non caricato"
        case .unknown:           return "Sconosciuto"
        }
    }

    /// True se la traccia è ospitata in iCloud (abbinata/caricata/acquistata/abbonamento).
    public var isCloudHosted: Bool {
        switch self {
        case .matched, .uploaded, .purchased, .subscription: return true
        default: return false
        }
    }

    /// Codice 4-char Music.app corrispondente (inverso di `init(code:)`).
    public var code: String {
        switch self {
        case .none:              return ""
        case .purchased:         return "kPur"
        case .matched:           return "kMat"
        case .uploaded:          return "kUpl"
        case .subscription:      return "kSub"
        case .ineligible:        return "kIne"
        case .removed:           return "kRem"
        case .error:             return "kErr"
        case .duplicate:         return "kDpl"
        case .noLongerAvailable: return "kRdy"
        case .notUploaded:       return "kNot"
        case .unknown:           return "kUnk"
        }
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
