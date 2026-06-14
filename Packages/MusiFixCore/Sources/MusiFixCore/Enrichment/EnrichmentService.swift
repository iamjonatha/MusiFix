import Foundation
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "EnrichmentService")

/// Actor che coordina la ricerca di copertine e metadati da provider online.
/// Provider in ordine: iTunes Search API → MusicBrainz/Cover Art Archive.
/// Cache in-memory per la sessione corrente.
public actor EnrichmentService {

    private let session: URLSession
    private var cache: [String: [ArtworkCandidate]] = [:]

    // Rate limiter separato per provider
    private let iTunesRate = RateLimiter(interval: 0.5)
    private let mbRate = RateLimiter(interval: 1.1) // MusicBrainz: max 1 req/s

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // ── Ricerca candidati ─────────────────────────────────────────────────────

    /// Cerca copertine per albumArtist + album su tutti i provider.
    /// Restituisce i candidati ordinati per score decrescente.
    public func search(albumArtist: String, album: String) async -> [ArtworkCandidate] {
        let key = cacheKey(albumArtist, album)
        if let cached = cache[key] {
            log.debug("Cache hit: \(key)")
            return cached
        }

        log.info("Ricerca copertina: \"\(albumArtist)\" — \"\(album)\"")
        var results: [ArtworkCandidate] = []

        async let itunesTask = searchiTunes(albumArtist: albumArtist, album: album)
        let itunes = await (try? itunesTask) ?? []
        results.append(contentsOf: itunes)

        let mb = (try? await searchMusicBrainz(albumArtist: albumArtist, album: album)) ?? []
        results.append(contentsOf: mb)

        results.sort { $0.score > $1.score }
        cache[key] = results
        log.info("Trovati \(results.count) candidati per \"\(album)\"")
        return results
    }

    /// Scarica i dati immagine da un URL (usato per il download "full" al momento dell'applicazione).
    public func fetchImageData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.downloadFailed(url)
        }
        return data
    }

    /// Svuota la cache in-memory (es. all'avvio di una nuova sessione di indicizzazione).
    public func clearCache() { cache.removeAll() }

    // ── iTunes Search API ─────────────────────────────────────────────────────

    private func searchiTunes(albumArtist: String, album: String) async throws -> [ArtworkCandidate] {
        await iTunesRate.wait()

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term",   value: "\(albumArtist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "limit",  value: "8"),
        ]
        guard let url = components.url else { return [] }

        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)

        return response.results.compactMap { result -> ArtworkCandidate? in
            guard let artBase = result.artworkUrl100,
                  let previewURL = URL(string: artBase.replacingOccurrences(of: "100x100bb", with: "250x250bb")),
                  let fullURL   = URL(string: artBase.replacingOccurrences(of: "100x100bb", with: "1400x1400bb"))
            else { return nil }

            let year = result.releaseDate.flatMap { parseYear($0) }
            let artistScore = tokenSimilarity(albumArtist, result.artistName ?? "")
            let albumScore  = tokenSimilarity(album,       result.collectionName ?? "")
            let score = artistScore * 0.4 + albumScore * 0.6

            return ArtworkCandidate(
                previewURL: previewURL, fullURL: fullURL,
                year: year, provider: "iTunes",
                collectionName: result.collectionName ?? album,
                artistName: result.artistName ?? albumArtist,
                score: score
            )
        }
    }

    // ── MusicBrainz / Cover Art Archive ──────────────────────────────────────

    private func searchMusicBrainz(albumArtist: String, album: String) async throws -> [ArtworkCandidate] {
        await mbRate.wait()

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(albumArtist)\" AND release:\"\(album)\""),
            URLQueryItem(name: "fmt",   value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("MusiFix/0.1 (jonatha.panni@gmail.com)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(MBSearchResponse.self, from: data)

        var candidates: [ArtworkCandidate] = []

        for release in response.releases where release.coverArtArchive?.front == true {
            await mbRate.wait() // rispetta 1 req/s anche per CAA
            guard let mbid = release.id else { continue }

            let previewURLStr = "https://coverartarchive.org/release/\(mbid)/front-250"
            let fullURLStr    = "https://coverartarchive.org/release/\(mbid)/front"
            guard let previewURL = URL(string: previewURLStr),
                  let fullURL    = URL(string: fullURLStr) else { continue }

            // Verifica HEAD che l'immagine esista (CAA può restituire 404)
            var headReq = URLRequest(url: previewURL)
            headReq.httpMethod = "HEAD"
            guard let (_, headResp) = try? await session.data(for: headReq),
                  (headResp as? HTTPURLResponse)?.statusCode == 200 else { continue }

            let year = release.date.flatMap { parseYear($0) }
            let artistName = release.artistCredit?.first?.name
                ?? release.artistCredit?.first?.artist?.name ?? albumArtist
            let artistScore = tokenSimilarity(albumArtist, artistName)
            let albumScore  = tokenSimilarity(album, release.title ?? "")
            let mbScore = Double(release.score ?? 0) / 100.0
            let score = artistScore * 0.3 + albumScore * 0.5 + mbScore * 0.2

            candidates.append(ArtworkCandidate(
                previewURL: previewURL, fullURL: fullURL,
                year: year, provider: "MusicBrainz",
                collectionName: release.title ?? album,
                artistName: artistName,
                score: score
            ))
        }

        return candidates
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func cacheKey(_ artist: String, _ album: String) -> String {
        "\(artist.lowercased()):\(album.lowercased())"
    }

    private func parseYear(_ s: String) -> Int? {
        if let y = Int(s.prefix(4)), y > 1900, y < 2100 { return y }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd", "yyyy-MM"] {
            fmt.dateFormat = format
            if let d = fmt.date(from: s) {
                return Calendar.current.component(.year, from: d)
            }
        }
        return nil
    }
}

// ── Rate limiter ──────────────────────────────────────────────────────────────

actor RateLimiter {
    private let interval: TimeInterval
    private var lastCall: Date = .distantPast

    init(interval: TimeInterval) { self.interval = interval }

    func wait() async {
        let elapsed = Date().timeIntervalSince(lastCall)
        if elapsed < interval {
            try? await Task.sleep(for: .seconds(interval - elapsed))
        }
        lastCall = Date()
    }
}

// ── Errori ────────────────────────────────────────────────────────────────────

public enum EnrichmentError: Error, LocalizedError {
    case downloadFailed(URL)
    case noResults

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "Download fallito: \(url.host ?? url.absoluteString)"
        case .noResults:               return "Nessun candidato trovato."
        }
    }
}

// ── Codable iTunes ────────────────────────────────────────────────────────────

private struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesAlbum]
}

private struct iTunesAlbum: Codable {
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?
    let releaseDate: String?
}

// ── Codable MusicBrainz ───────────────────────────────────────────────────────

private struct MBSearchResponse: Codable {
    let releases: [MBRelease]
}

private struct MBRelease: Codable {
    let id: String?
    let title: String?
    let date: String?
    let score: Int?
    let artistCredit: [MBArtistCredit]?
    let coverArtArchive: MBCoverArtArchive?

    enum CodingKeys: String, CodingKey {
        case id, title, date, score
        case artistCredit = "artist-credit"
        case coverArtArchive = "cover-art-archive"
    }
}

private struct MBArtistCredit: Codable {
    let name: String?
    let artist: MBArtist?
}

private struct MBArtist: Codable {
    let name: String?
}

private struct MBCoverArtArchive: Codable {
    let front: Bool?
    let count: Int?
}
