import Foundation
import Persistence

/// Feature estratte da una playlist (Fase 23). Calcolate solo dai metadati già
/// presenti in `DBTrack` — tonalità/tempo/energia non sono disponibili da Music
/// (richiederebbero DSP sui file audio, vedi Fase 24) e restano `nil` in v1.
/// Predisposti così scorer e UI non richiederanno modifiche quando quella fase
/// verrà eventualmente implementata.
public struct PlaylistFeatures: Sendable {
    public struct ArtistStat: Sendable {
        public let name: String
        public let count: Int
        public let percentage: Double
        public init(name: String, count: Int, percentage: Double) {
            self.name = name; self.count = count; self.percentage = percentage
        }
    }

    public struct GenreStat: Sendable {
        public let name: String
        public let count: Int
        public let percentage: Double
        public init(name: String, count: Int, percentage: Double) {
            self.name = name; self.count = count; self.percentage = percentage
        }
    }

    public let trackCount: Int
    public let totalDuration: Double

    // Artisti
    /// Include gli artisti "featuring" estratti da titolo/artista (vedi `FeaturingParser`):
    /// la percentuale è la quota di brani in cui l'artista compare, come primario o ospite.
    public let topArtists: [ArtistStat]
    public let dominantArtistPercentage: Double
    public let maxConsecutiveRepeats: Int
    /// Numero di artisti distinti coinvolti (primari + ospiti/featuring).
    public let distinctArtistCount: Int

    // Generi
    public let genreDistribution: [GenreStat]
    /// Indice di diversità di Shannon normalizzato in [0,1] (0 = monogenere, 1 = massima varietà).
    public let genreDiversityIndex: Double
    public let dominantGenrePercentage: Double

    // Anni
    public let yearRange: ClosedRange<Int>?
    public let distinctDecadesCount: Int
    public let yearStdDeviation: Double

    // Durate
    public let averageDuration: Double
    public let durationStdDeviation: Double
    /// Durate nell'ordine della playlist (per un eventuale grafico dell'arco).
    public let durationSequence: [Double]

    // Predisposizione Fase 24 (analisi audio DSP): nil finché non implementata.
    public let averageTempo: Double?
    public let dominantKey: String?
    public let averageEnergy: Double?
}

/// Calcola `PlaylistFeatures` da un insieme di brani. Dietro protocollo per
/// permettere in futuro un estrattore che integri anche l'analisi audio (Fase 24)
/// senza toccare `PlaylistScorer` o la UI.
public protocol PlaylistFeatureExtractor: Sendable {
    func extract(from tracks: [DBTrack]) -> PlaylistFeatures
}

/// v1: unico estrattore, basato sui metadati già indicizzati.
public struct MetadataFeatureExtractor: PlaylistFeatureExtractor {
    public init() {}

    public func extract(from tracks: [DBTrack]) -> PlaylistFeatures {
        guard !tracks.isEmpty else {
            return PlaylistFeatures(
                trackCount: 0, totalDuration: 0,
                topArtists: [], dominantArtistPercentage: 0, maxConsecutiveRepeats: 0,
                distinctArtistCount: 0,
                genreDistribution: [], genreDiversityIndex: 0, dominantGenrePercentage: 0,
                yearRange: nil, distinctDecadesCount: 0, yearStdDeviation: 0,
                averageDuration: 0, durationStdDeviation: 0, durationSequence: [],
                averageTempo: nil, dominantKey: nil, averageEnergy: nil
            )
        }
        let n = Double(tracks.count)

        // Artista di riferimento: albumArtist se presente, altrimenti artist
        // (coerente con il raggruppamento usato in AlbumDAO).
        func artistOf(_ t: DBTrack) -> String {
            let a = t.albumArtist.trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? t.artist : a
        }

        // Conteggio artisti "presenti": primario + eventuali featuring dal titolo/artista.
        // Ogni artista è contato una sola volta per brano (un ospite non gonfia il totale
        // se coincide col primario).
        var artistCounts: [String: Int] = [:]
        for t in tracks {
            var perTrack = Set<String>()
            perTrack.insert(artistOf(t))
            for guest in FeaturingParser.featuredArtists(title: t.name, artist: t.artist) {
                perTrack.insert(guest)
            }
            for name in perTrack where !name.isEmpty { artistCounts[name, default: 0] += 1 }
        }
        let topArtists: [PlaylistFeatures.ArtistStat] = artistCounts.sorted { $0.value > $1.value }.prefix(5).map {
            PlaylistFeatures.ArtistStat(name: $0.key, count: $0.value, percentage: Double($0.value) / n * 100)
        }
        let dominantArtistPct = topArtists.first?.percentage ?? 0

        var maxRepeat = 1
        var curRepeat = 1
        for i in 1..<tracks.count {
            let prev = artistOf(tracks[i - 1]), cur = artistOf(tracks[i])
            if !cur.isEmpty, cur == prev {
                curRepeat += 1
                maxRepeat = max(maxRepeat, curRepeat)
            } else {
                curRepeat = 1
            }
        }

        var genreCounts: [String: Int] = [:]
        for t in tracks {
            let g = t.genre.trimmingCharacters(in: .whitespaces)
            genreCounts[g.isEmpty ? "Sconosciuto" : g, default: 0] += 1
        }
        let genreDist: [PlaylistFeatures.GenreStat] = genreCounts.sorted { $0.value > $1.value }.map {
            PlaylistFeatures.GenreStat(name: $0.key, count: $0.value, percentage: Double($0.value) / n * 100)
        }
        let dominantGenrePct = genreDist.first?.percentage ?? 0
        let entropy = genreCounts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
        let maxEntropy = genreCounts.count > 1 ? log2(Double(genreCounts.count)) : 0
        let diversityIndex = maxEntropy > 0 ? entropy / maxEntropy : 0

        let years = tracks.map(\.year).filter { $0 > 0 }
        let yearRange: ClosedRange<Int>? = years.isEmpty ? nil : (years.min()!...years.max()!)
        let decades = Set(years.map { ($0 / 10) * 10 })
        let yearMean = years.isEmpty ? 0 : Double(years.reduce(0, +)) / Double(years.count)
        let yearVariance = years.isEmpty ? 0
            : years.reduce(0.0) { $0 + pow(Double($1) - yearMean, 2) } / Double(years.count)

        let durations = tracks.map(\.duration)
        let avgDuration = durations.reduce(0, +) / n
        let durVariance = durations.reduce(0.0) { $0 + pow($1 - avgDuration, 2) } / n

        return PlaylistFeatures(
            trackCount: tracks.count,
            totalDuration: durations.reduce(0, +),
            topArtists: Array(topArtists),
            dominantArtistPercentage: dominantArtistPct,
            maxConsecutiveRepeats: maxRepeat,
            distinctArtistCount: artistCounts.count,
            genreDistribution: genreDist,
            genreDiversityIndex: diversityIndex,
            dominantGenrePercentage: dominantGenrePct,
            yearRange: yearRange,
            distinctDecadesCount: decades.count,
            yearStdDeviation: sqrt(yearVariance),
            averageDuration: avgDuration,
            durationStdDeviation: sqrt(durVariance),
            durationSequence: durations,
            averageTempo: nil,
            dominantKey: nil,
            averageEnergy: nil
        )
    }
}
