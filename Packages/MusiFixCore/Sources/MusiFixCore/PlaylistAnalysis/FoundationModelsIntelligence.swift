import Foundation
import FoundationModels

/// Implementazione via Apple Intelligence on-device (FoundationModels, macOS 26+).
/// L'app ha deployment target 14.0: questo tipo è utilizzabile solo dietro un
/// `if #available(macOS 26, *)` (vedi `PlaylistAnalysisService.makeIntelligence`).
@available(macOS 26, *)
public struct FoundationModelsIntelligence: PlaylistIntelligence {
    public init() {}

    public var isAvailable: Bool {
        get async { SystemLanguageModel.default.availability == .available }
    }

    public func narrate(
        playlistName: String,
        features: PlaylistFeatures,
        scores: PlaylistScores,
        goal: PlaylistGoal
    ) async throws -> PlaylistNarrative {
        guard await isAvailable else {
            throw MusiFixError.appleScriptError("Modello Apple Intelligence non disponibile su questo Mac")
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = Self.buildPrompt(playlistName: playlistName, features: features, scores: scores, goal: goal)
        let response = try await session.respond(to: prompt)
        return Self.parse(response.content)
    }

    private static let instructions = """
        Sei un assistente musicale che analizza playlist a partire da statistiche \
        aggregate: non hai accesso all'audio. Rispondi in italiano, in modo conciso: \
        un paragrafo di sintesi seguito da un elenco puntato di massimo 4 suggerimenti \
        pratici (riordino, rimozione, aggiunta di brani) per avvicinare la playlist \
        all'obiettivo indicato dall'utente. Ogni suggerimento va su una riga che inizia con "-".
        """

    private static func buildPrompt(
        playlistName: String, features: PlaylistFeatures, scores: PlaylistScores, goal: PlaylistGoal
    ) -> String {
        var lines = [
            "Playlist: \(playlistName)",
            "Obiettivo desiderato: \(goal.label)",
            "Brani: \(features.trackCount), durata totale \(Int(features.totalDuration / 60)) min",
            "Punteggi euristici — coerenza \(scores.coherence)/100, varietà \(scores.variety)/100, bilanciamento \(scores.balance)/100",
            "Artista dominante: " + (features.topArtists.first.map { "\($0.name) (\(Int($0.percentage))%)" } ?? "nessuno"),
            "Massime ripetizioni consecutive dello stesso artista: \(features.maxConsecutiveRepeats)",
            "Genere dominante: " + (features.genreDistribution.first.map { "\($0.name) (\(Int($0.percentage))%)" } ?? "nessuno")
                + ", indice di diversità generi: " + String(format: "%.2f", features.genreDiversityIndex),
        ]
        if let range = features.yearRange {
            lines.append("Anni: da \(range.lowerBound) a \(range.upperBound) (\(features.distinctDecadesCount) decadi)")
        }
        return lines.joined(separator: "\n")
    }

    /// Separa il paragrafo introduttivo dai punti elenco (righe che iniziano con "-" o "•").
    private static func parse(_ text: String) -> PlaylistNarrative {
        var narrative: [String] = []
        var suggestions: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") {
                let cleaned = trimmed.drop(while: { $0 == "-" || $0 == "•" || $0 == " " })
                if !cleaned.isEmpty { suggestions.append(String(cleaned)) }
            } else if !trimmed.isEmpty {
                narrative.append(trimmed)
            }
        }
        return PlaylistNarrative(text: narrative.joined(separator: " "), suggestions: suggestions)
    }
}
