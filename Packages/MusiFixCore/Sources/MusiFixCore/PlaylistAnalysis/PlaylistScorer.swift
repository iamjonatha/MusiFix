import Foundation

/// Punteggi euristici 0-100 sui tre assi di valutazione di una playlist (Fase 23).
public struct PlaylistScores: Sendable {
    public let coherence: Int
    public let variety: Int
    public let balance: Int

    public init(coherence: Int, variety: Int, balance: Int) {
        self.coherence = coherence; self.variety = variety; self.balance = balance
    }
}

/// Obiettivo desiderato per la playlist, scelto dall'utente prima dell'analisi.
public enum PlaylistGoal: String, Sendable, CaseIterable, Identifiable {
    case coherent, varied, balanced
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .coherent: return "Coerente"
        case .varied:   return "Variegata"
        case .balanced: return "Bilanciata"
        }
    }
}

/// Calcola i punteggi 0-100 da `PlaylistFeatures`. Sempre disponibile (nessuna
/// dipendenza esterna), a differenza di `PlaylistIntelligence` che richiede
/// Apple Intelligence.
public protocol PlaylistScorer: Sendable {
    func score(_ features: PlaylistFeatures) -> PlaylistScores
}

/// v1: euristiche pure sui metadati. Non usa i campi tempo/key/energy (nil in v1);
/// quando la Fase 24 li popolerà, questo scorer potrà incorporarli senza che la UI
/// debba cambiare (la firma resta `(PlaylistFeatures) -> PlaylistScores`).
public struct HeuristicPlaylistScorer: PlaylistScorer {
    public init() {}

    public func score(_ f: PlaylistFeatures) -> PlaylistScores {
        guard f.trackCount > 0 else { return PlaylistScores(coherence: 0, variety: 0, balance: 0) }

        // Coerenza: genere concentrato + spread anni contenuto.
        let genreCoherence = f.dominantGenrePercentage / 100
        let yearCoherence: Double = {
            guard let range = f.yearRange else { return 0.5 }
            let span = Double(range.upperBound - range.lowerBound)
            return max(0, 1 - span / 40) // 40 anni di spread ⇒ coerenza nulla
        }()
        let coherence = ((genreCoherence * 0.6 + yearCoherence * 0.4) * 100).rounded()

        // Varietà: generi diversificati, nessun artista dominante, decadi multiple.
        let artistVariety = 1 - (f.dominantArtistPercentage / 100)
        let genreVariety = f.genreDiversityIndex
        let decadeVariety = min(Double(f.distinctDecadesCount) / 5, 1)
        let variety = ((artistVariety * 0.4 + genreVariety * 0.4 + decadeVariety * 0.2) * 100).rounded()

        // Bilanciamento: penalizza ripetizioni consecutive di artista e outlier di durata.
        let consecutivePenalty = min(Double(f.maxConsecutiveRepeats - 1) / 5, 1)
        let durationBalance = f.averageDuration > 0
            ? max(0, 1 - (f.durationStdDeviation / f.averageDuration))
            : 0.5
        let balance = ((durationBalance * 0.5 + (1 - consecutivePenalty) * 0.5) * 100).rounded()

        func clamp(_ v: Double) -> Int { min(max(Int(v), 0), 100) }
        return PlaylistScores(coherence: clamp(coherence), variety: clamp(variety), balance: clamp(balance))
    }
}
