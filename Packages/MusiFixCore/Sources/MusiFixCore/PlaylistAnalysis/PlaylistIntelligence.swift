import Foundation

/// Sintesi qualitativa generata dal modello: un paragrafo narrativo più una lista
/// di suggerimenti pratici (riordino, rimozione, aggiunta di brani).
public struct PlaylistNarrative: Sendable {
    public let text: String
    public let suggestions: [String]

    public init(text: String, suggestions: [String]) {
        self.text = text; self.suggestions = suggestions
    }
}

/// Genera la narrativa di una playlist a partire da feature + punteggi euristici
/// già calcolati. Dietro protocollo per poter agganciare in futuro un provider
/// cloud senza toccare `PlaylistAnalysisService` o la UI. v1: solo FoundationModels
/// on-device (macOS 26+); se non disponibile la UI mostra solo le euristiche.
public protocol PlaylistIntelligence: Sendable {
    var isAvailable: Bool { get async }
    func narrate(
        playlistName: String,
        features: PlaylistFeatures,
        scores: PlaylistScores,
        goal: PlaylistGoal
    ) async throws -> PlaylistNarrative
}

/// Usato quando Apple Intelligence non è disponibile sul Mac corrente (macOS < 26,
/// dispositivo non idoneo, funzione non abilitata, modello non pronto).
public struct UnavailableIntelligence: PlaylistIntelligence {
    public init() {}
    public var isAvailable: Bool { false }
    public func narrate(
        playlistName: String, features: PlaylistFeatures, scores: PlaylistScores, goal: PlaylistGoal
    ) async throws -> PlaylistNarrative {
        throw MusiFixError.appleScriptError("Apple Intelligence non disponibile su questo Mac")
    }
}
