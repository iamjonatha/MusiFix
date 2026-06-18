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
    // Limiter conservativo per gli scan di massa (Fase D): evita i 403 di iTunes
    private let albumScanRate = RateLimiter(interval: 3.0)

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // ── Ricerca candidati ─────────────────────────────────────────────────────

    /// Cerca copertine per albumArtist + album su tutti i provider.
    /// Se trackTitle è fornito e diverso da album, esegue una seconda query iTunes
    /// "artista + titolo" e unisce i risultati (dedup per URL, score massimo).
    public func search(albumArtist: String, album: String, trackTitle: String = "") async -> [ArtworkCandidate] {
        let useTitle = !trackTitle.isEmpty && trackTitle.lowercased() != album.lowercased()
        let key = cacheKey(albumArtist, album, trackTitle)
        if let cached = cache[key] {
            log.debug("Cache hit: \(key)")
            return cached
        }

        let titleNote = useTitle ? " / \"\(trackTitle)\"" : ""
        log.info("Ricerca copertina: \"\(albumArtist)\" — \"\(album)\"\(titleNote)")

        // iTunes: ricerca per album (parallela con MB)
        async let itunesAlbumTask = searchiTunes(albumArtist: albumArtist, album: album)
        let itunesAlbum = await (try? itunesAlbumTask) ?? []

        // MusicBrainz: ricerca per album
        let mb = (try? await searchMusicBrainz(albumArtist: albumArtist, album: album)) ?? []

        // iTunes: seconda ricerca per titolo brano (se diverso da album)
        var itunesTitle: [ArtworkCandidate] = []
        if useTitle {
            let raw = (try? await searchiTunes(albumArtist: albumArtist, album: trackTitle)) ?? []
            // Re-score: usa max(album_sim, title_sim) per non penalizzare risultati validi
            itunesTitle = raw.map { c in
                let artistSim = tokenSimilarity(albumArtist, c.artistName)
                let albumSim  = tokenSimilarity(album,       c.collectionName)
                let titleSim  = tokenSimilarity(trackTitle,  c.collectionName)
                return c.withScore(artistSim * 0.4 + max(albumSim, titleSim) * 0.6)
            }
        }

        // Merge: dedup per fullURL, mantieni score massimo
        var byURL: [URL: ArtworkCandidate] = [:]
        for c in itunesAlbum + mb + itunesTitle {
            if let existing = byURL[c.fullURL] {
                if c.score > existing.score { byURL[c.fullURL] = c }
            } else {
                byURL[c.fullURL] = c
            }
        }

        let results = byURL.values.sorted { $0.score > $1.score }
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

    // ── Lookup album (Fase D): conteggio tracce autorevole ──────────────────────

    public struct AlbumLookupResult: Sendable {
        public let collectionId: Int
        public let storeTrackCount: Int
        public let collectionName: String
        public let artistName: String
    }

    /// Cerca su iTunes l'album e ne restituisce `collectionId` + `trackCount`
    /// autorevole. Sceglie il risultato con la massima similarità su artista+album.
    /// Usa il rate limiter conservativo (3 s) adatto agli scan di massa.
    public func lookupAlbum(albumArtist: String, album: String) async throws -> AlbumLookupResult? {
        await albumScanRate.wait()

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term",   value: "\(albumArtist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "limit",  value: "10"),
        ]
        guard let url = components.url else { return nil }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.downloadFailed(url)
        }
        let decoded = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)

        // Sceglie il miglior match con collectionId + trackCount presenti.
        var best: (score: Double, result: AlbumLookupResult)?
        for r in decoded.results {
            guard let cid = r.collectionId, let count = r.trackCount, count > 0 else { continue }
            let artistSim = tokenSimilarity(albumArtist, r.artistName ?? "")
            let albumSim  = tokenSimilarity(album,       r.collectionName ?? "")
            let score = artistSim * 0.4 + albumSim * 0.6
            if best == nil || score > best!.score {
                best = (score, AlbumLookupResult(
                    collectionId: cid, storeTrackCount: count,
                    collectionName: r.collectionName ?? album,
                    artistName: r.artistName ?? albumArtist
                ))
            }
        }
        // Soglia minima di confidenza sul match
        guard let b = best, b.score >= 0.5 else { return nil }
        return b.result
    }

    // ── Lookup tracce di una collection (Fase E): durate dallo Store ────────────

    // ── Lookup candidati album (Fase G): top-N con anno e conteggio dischi ──────

    public struct AlbumLookupCandidate: Sendable {
        public let collectionId: Int
        public let storeTrackCount: Int
        public let discCount: Int
        public let collectionName: String
        public let artistName: String
        public let year: Int?
        public let score: Double
    }

    /// Restituisce i top-N candidati album su iTunes, ordinati per score.
    /// Permette di scegliere l'edizione corretta prima di proporre i numeri (Fase G).
    public func lookupAlbumCandidates(albumArtist: String, album: String, limit: Int = 8) async throws -> [AlbumLookupCandidate] {
        await albumScanRate.wait()

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term",   value: "\(albumArtist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "limit",  value: "\(min(limit, 25))"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.downloadFailed(url)
        }
        let decoded = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)

        return decoded.results.compactMap { r -> AlbumLookupCandidate? in
            guard let cid = r.collectionId, let count = r.trackCount, count > 0 else { return nil }
            let artistSim = tokenSimilarity(albumArtist, r.artistName ?? "")
            let albumSim  = tokenSimilarity(album,       r.collectionName ?? "")
            let score = artistSim * 0.4 + albumSim * 0.6
            guard score >= 0.3 else { return nil }
            return AlbumLookupCandidate(
                collectionId: cid,
                storeTrackCount: count,
                discCount: r.discCount ?? 1,
                collectionName: r.collectionName ?? album,
                artistName: r.artistName ?? albumArtist,
                year: r.releaseDate.flatMap { parseYear($0) },
                score: score
            )
        }
        .sorted { $0.score > $1.score }
    }

    public struct StoreTrack: Sendable {
        public let trackName: String
        public let trackNumber: Int
        public let trackCount: Int
        public let discNumber: Int
        public let discCount: Int
        public let durationSeconds: Double   // da trackTimeMillis
    }

    /// Recupera le tracce di una collection iTunes (via `lookup?id=…&entity=song`),
    /// con nome, numero, disco e durata. Usa il rate limiter conservativo.
    public func lookupCollectionTracks(collectionId: Int) async throws -> [StoreTrack] {
        await albumScanRate.wait()

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id",     value: "\(collectionId)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit",  value: "200"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.downloadFailed(url)
        }
        let decoded = try JSONDecoder().decode(iTunesLookupResponse.self, from: data)
        return decoded.results.compactMap { r -> StoreTrack? in
            guard r.wrapperType == "track", let ms = r.trackTimeMillis, let name = r.trackName
            else { return nil }
            return StoreTrack(
                trackName: name,
                trackNumber: r.trackNumber ?? 0,
                trackCount: r.trackCount ?? 0,
                discNumber: r.discNumber ?? 1,
                discCount: r.discCount ?? 1,
                durationSeconds: Double(ms) / 1000.0
            )
        }
    }

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

    private func cacheKey(_ artist: String, _ album: String, _ title: String = "") -> String {
        "\(artist.lowercased()):\(album.lowercased()):\(title.lowercased())"
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
    let collectionId: Int?
    let trackCount: Int?
    let discCount: Int?
}

// ── Codable iTunes lookup (entity=song) ─────────────────────────────────────────

private struct iTunesLookupResponse: Codable {
    let results: [iTunesSong]
}

private struct iTunesSong: Codable {
    let wrapperType: String?
    let trackName: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    let trackTimeMillis: Int?
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
