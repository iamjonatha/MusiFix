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
    func narrate(_ input: PlaylistNarrationInput) async throws -> PlaylistNarrative
}

/// Dati passati al modello per generare la narrativa. Raggruppati in una struct
/// per far evolvere l'input (descrizione utente, campione brani, …) senza cambiare
/// la firma del protocollo a ogni aggiunta.
public struct PlaylistNarrationInput: Sendable {
    public let playlistName: String
    public let features: PlaylistFeatures
    public let scores: PlaylistScores
    public let goal: PlaylistGoal
    /// Descrizione libera della playlist inserita dall'utente (può essere vuota).
    public let userDescription: String
    /// Risultato desiderato in forma testuale inserito dall'utente (può essere vuoto).
    public let desiredResult: String
    /// Campione dei brani nell'ordine attuale ("Titolo — Artista"), per suggerimenti concreti.
    public let trackSample: [String]

    public init(
        playlistName: String, features: PlaylistFeatures, scores: PlaylistScores,
        goal: PlaylistGoal, userDescription: String, desiredResult: String, trackSample: [String]
    ) {
        self.playlistName = playlistName
        self.features = features
        self.scores = scores
        self.goal = goal
        self.userDescription = userDescription
        self.desiredResult = desiredResult
        self.trackSample = trackSample
    }
}

/// Usato quando Apple Intelligence non è disponibile sul Mac corrente (macOS < 26,
/// dispositivo non idoneo, funzione non abilitata, modello non pronto).
public struct UnavailableIntelligence: PlaylistIntelligence {
    public init() {}
    public var isAvailable: Bool { false }
    public func narrate(_ input: PlaylistNarrationInput) async throws -> PlaylistNarrative {
        throw MusiFixError.appleScriptError("Apple Intelligence non disponibile su questo Mac")
    }
}
