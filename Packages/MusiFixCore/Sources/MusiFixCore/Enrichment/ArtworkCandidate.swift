import Foundation

/// Candidato copertina restituito da un provider di arricchimento.
public struct ArtworkCandidate: Sendable, Identifiable {
    public var id: UUID = UUID()
    public let previewURL: URL        // thumbnail ~250px per la griglia
    public let fullURL: URL           // immagine originale da applicare
    public let year: Int?
    public let provider: String       // "iTunes" | "MusicBrainz" | "Deezer" | "Discogs"
    public let collectionName: String
    public let artistName: String
    public let score: Double          // 0…1, similarità con la query

    public init(previewURL: URL, fullURL: URL, year: Int?,
                provider: String, collectionName: String,
                artistName: String, score: Double) {
        self.previewURL = previewURL; self.fullURL = fullURL
        self.year = year; self.provider = provider
        self.collectionName = collectionName; self.artistName = artistName
        self.score = score
    }

    public func withScore(_ s: Double) -> ArtworkCandidate {
        ArtworkCandidate(previewURL: previewURL, fullURL: fullURL, year: year,
                         provider: provider, collectionName: collectionName,
                         artistName: artistName, score: s)
    }
}

// ── Jaccard similarity su token ───────────────────────────────────────────────

func tokenSimilarity(_ a: String, _ b: String) -> Double {
    func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 1 })
    }
    let ta = tokens(a); let tb = tokens(b)
    guard !ta.isEmpty, !tb.isEmpty else { return 0 }
    let inter = ta.intersection(tb).count
    let union = ta.union(tb).count
    return Double(inter) / Double(union)
}
