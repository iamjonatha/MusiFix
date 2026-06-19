import Foundation
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "YearResolutionService")

// ── Risultato ───────────────────────────────────────────────────────────────────

/// Un singolo anno candidato proposto da un provider, con il contesto che lo motiva.
public struct YearCandidate: Sendable, Identifiable {
    public let id = UUID()
    public let year: Int
    public let provider: String        // "MusicBrainz" | "iTunes"
    public let sourceTitle: String     // titolo recording/release che ha prodotto l'anno
    public let artistName: String
    public let confidence: Double      // 0…1, qualità del match (artista+titolo+durata)

    public init(year: Int, provider: String, sourceTitle: String,
                artistName: String, confidence: Double) {
        self.year = year; self.provider = provider
        self.sourceTitle = sourceTitle; self.artistName = artistName
        self.confidence = confidence
    }
}

/// Esito della risoluzione anno per un brano.
public struct YearResolution: Sendable {
    /// Miglior stima dell'anno di PRIMA pubblicazione (originale), o nil se non affidabile.
    public let suggestedYear: Int?
    /// Anno attualmente presente nel brano (0 = assente).
    public let currentYear: Int
    /// Tutti i candidati trovati, ordinati per anno crescente (per scelta manuale).
    public let candidates: [YearCandidate]
    /// True se album/titolo contengono marcatori di ristampa (remaster, deluxe, …):
    /// indica che l'anno attuale è probabilmente quello dell'edizione, non dell'originale.
    public let currentYearLikelyReissue: Bool

    /// True se applicare il suggerimento cambierebbe l'anno corrente.
    public var changesYear: Bool {
        guard let s = suggestedYear else { return false }
        return s != currentYear
    }

    public init(suggestedYear: Int?, currentYear: Int,
                candidates: [YearCandidate], currentYearLikelyReissue: Bool) {
        self.suggestedYear = suggestedYear
        self.currentYear = currentYear
        self.candidates = candidates
        self.currentYearLikelyReissue = currentYearLikelyReissue
    }
}

// ── Servizio ────────────────────────────────────────────────────────────────────

/// Risolve l'anno di **prima pubblicazione** di un brano.
///
/// Strategia (deterministica, nessun LLM): interroga MusicBrainz cercando il
/// *recording* per artista+titolo e raccoglie tutte le date plausibili dai campi
/// `first-release-date` (recording e release-group). Tra i match validi sceglie
/// l'**anno minimo plausibile**: così un brano del 1979 ripubblicato su un remaster
/// 2023 restituisce 1979, non 2023. iTunes è usato solo come fallback.
public actor YearResolutionService {

    private let session: URLSession
    private let mbRate = RateLimiter(interval: 1.1)      // MusicBrainz: max 1 req/s
    private let iTunesRate = RateLimiter(interval: 0.5)

    /// Soglia minima di confidenza perché un candidato concorra al suggerimento automatico.
    private static let confidenceFloor = 0.55
    /// Tolleranza sulla durata (s) per considerare due registrazioni la stessa.
    private static let durationToleranceSeconds = 8.0
    /// Anno minimo ritenuto plausibile per musica registrata.
    private static let minPlausibleYear = 1900

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    // ── API pubblica ────────────────────────────────────────────────────────────

    /// Risolve l'anno originale per un brano.
    /// - Parameters:
    ///   - title: titolo del brano.
    ///   - artist: artista (esecutore). Usato per filtrare i match.
    ///   - album: album corrente (per il rilevamento marcatori di ristampa).
    ///   - currentYear: anno attualmente presente (0 se assente).
    ///   - durationSeconds: durata del brano in secondi (0 se sconosciuta) per disambiguare cover/live.
    public func resolveYear(
        title: String,
        artist: String,
        album: String,
        currentYear: Int,
        durationSeconds: Double
    ) async -> YearResolution {
        let reissue = Self.hasReissueMarker(album) || Self.hasReissueMarker(title)

        var candidates = await (try? searchMusicBrainz(
            title: title, artist: artist, durationSeconds: durationSeconds
        )) ?? []

        // Fallback iTunes solo se MusicBrainz non ha prodotto nulla.
        if candidates.isEmpty {
            candidates += await (try? searchiTunes(
                title: title, artist: artist, durationSeconds: durationSeconds
            )) ?? []
        }

        candidates.sort { $0.year < $1.year }

        // Suggerimento = anno minimo plausibile tra i candidati sopra soglia di confidenza.
        let suggested = candidates
            .filter { $0.confidence >= Self.confidenceFloor }
            .map(\.year)
            .min()

        log.info("Risoluzione anno \"\(artist) — \(title)\": \(candidates.count) candidati, suggerito \(suggested.map(String.init) ?? "—"), ristampa=\(reissue)")

        return YearResolution(
            suggestedYear: suggested,
            currentYear: currentYear,
            candidates: candidates,
            currentYearLikelyReissue: reissue
        )
    }

    // ── MusicBrainz ───────────────────────────────────────────────────────────────

    private func searchMusicBrainz(
        title: String, artist: String, durationSeconds: Double
    ) async throws -> [YearCandidate] {
        await mbRate.wait()

        let query = "artist:\"\(luceneEscape(artist))\" AND recording:\"\(luceneEscape(title))\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt",   value: "json"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("MusiFix/0.1 (jonatha.panni@gmail.com)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(MBRecordingSearch.self, from: data)

        var out: [YearCandidate] = []
        for rec in response.recordings {
            let recArtist = rec.artistCredit?.first?.name
                ?? rec.artistCredit?.first?.artist?.name ?? ""
            let artistSim = tokenSimilarity(artist, recArtist)
            let titleSim  = tokenSimilarity(title, rec.title ?? "")
            guard artistSim >= 0.6, titleSim >= 0.7 else { continue }

            // Disambiguazione per durata (se nota da entrambe le parti).
            let recSeconds = rec.length.map { Double($0) / 1000.0 }
            if durationSeconds > 0, let rs = recSeconds,
               abs(rs - durationSeconds) > Self.durationToleranceSeconds {
                continue
            }
            let durationScore: Double
            if durationSeconds > 0, let rs = recSeconds {
                durationScore = 1 - min(abs(rs - durationSeconds) / Self.durationToleranceSeconds, 1)
            } else {
                durationScore = 0.5
            }
            let confidence = artistSim * 0.4 + titleSim * 0.4 + durationScore * 0.2

            // Date candidate: first-release-date del recording e dei release-group.
            var years: [Int] = []
            if let y = parseYear(rec.firstReleaseDate) { years.append(y) }
            for rel in rec.releases ?? [] {
                if let y = parseYear(rel.releaseGroup?.firstReleaseDate) { years.append(y) }
                if let y = parseYear(rel.date) { years.append(y) }
            }
            guard let recYear = years.min() else { continue }

            out.append(YearCandidate(
                year: recYear, provider: "MusicBrainz",
                sourceTitle: rec.title ?? title,
                artistName: recArtist.isEmpty ? artist : recArtist,
                confidence: confidence
            ))
        }
        return out
    }

    // ── iTunes (fallback) ─────────────────────────────────────────────────────────

    private func searchiTunes(
        title: String, artist: String, durationSeconds: Double
    ) async throws -> [YearCandidate] {
        await iTunesRate.wait()

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term",   value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "media",  value: "music"),
            URLQueryItem(name: "limit",  value: "25"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode(iTunesSongSearch.self, from: data)

        var out: [YearCandidate] = []
        for r in decoded.results {
            guard let year = parseYear(r.releaseDate) else { continue }
            let artistSim = tokenSimilarity(artist, r.artistName ?? "")
            let titleSim  = tokenSimilarity(title, r.trackName ?? "")
            guard artistSim >= 0.6, titleSim >= 0.7 else { continue }

            let secs = r.trackTimeMillis.map { Double($0) / 1000.0 }
            if durationSeconds > 0, let s = secs,
               abs(s - durationSeconds) > Self.durationToleranceSeconds { continue }
            let durationScore: Double
            if durationSeconds > 0, let s = secs {
                durationScore = 1 - min(abs(s - durationSeconds) / Self.durationToleranceSeconds, 1)
            } else {
                durationScore = 0.5
            }
            // iTunes dà la data dell'edizione: confidenza scontata rispetto a MusicBrainz.
            let confidence = (artistSim * 0.4 + titleSim * 0.4 + durationScore * 0.2) * 0.8

            out.append(YearCandidate(
                year: year, provider: "iTunes",
                sourceTitle: r.collectionName ?? r.trackName ?? title,
                artistName: r.artistName ?? artist,
                confidence: confidence
            ))
        }
        return out
    }

    // ── Helpers ───────────────────────────────────────────────────────────────────

    /// Marcatori che indicano un'edizione ristampata/rimasterizzata (IT + EN).
    private static let reissueMarkers = [
        "remaster", "remastered", "rimasterizzat", "ristampa",
        "anniversary", "anniversario", "deluxe", "reissue", "re-issue",
        "expanded", "bonus track", "super deluxe", "edizione speciale",
        "special edition", "greatest hits", "best of", "the very best",
        "collection", "anthology", "antologia",
    ]

    nonisolated static func hasReissueMarker(_ s: String) -> Bool {
        let lower = s.lowercased()
        if reissueMarkers.contains(where: lower.contains) { return true }
        // "(2009 ... Remaster)" o anni recenti accanto a parole di edizione già coperti sopra.
        return false
    }

    private func luceneEscape(_ s: String) -> String {
        // Rimuove le virgolette che spezzerebbero la query Lucene racchiusa tra "".
        s.replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseYear(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        if let y = Int(s.prefix(4)), y > Self.minPlausibleYear, y < 2100 { return y }
        return nil
    }
}

// ── Codable MusicBrainz (recording search) ──────────────────────────────────────

private struct MBRecordingSearch: Codable {
    let recordings: [MBRecording]
}

private struct MBRecording: Codable {
    let id: String?
    let title: String?
    let length: Int?                 // ms
    let firstReleaseDate: String?
    let artistCredit: [MBArtistCredit2]?
    let releases: [MBReleaseRef]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, releases
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit2: Codable {
    let name: String?
    let artist: MBArtist2?
}

private struct MBArtist2: Codable {
    let name: String?
}

private struct MBReleaseRef: Codable {
    let id: String?
    let title: String?
    let date: String?
    let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Codable {
    let id: String?
    let title: String?
    let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case firstReleaseDate = "first-release-date"
    }
}

// ── Codable iTunes (song search) ────────────────────────────────────────────────

private struct iTunesSongSearch: Codable {
    let results: [iTunesSongResult]
}

private struct iTunesSongResult: Codable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
}
