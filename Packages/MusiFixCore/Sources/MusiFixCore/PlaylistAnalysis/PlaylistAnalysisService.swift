import Foundation
import Persistence

/// Esito completo dell'analisi di una playlist (Fase 23): feature, punteggi
/// euristici (sempre presenti) ed eventuale narrativa Apple Intelligence.
public struct PlaylistAnalysis: Sendable {
    public let features: PlaylistFeatures
    public let scores: PlaylistScores
    public let narrative: PlaylistNarrative?
    /// Motivo per cui la narrativa non è disponibile (nil se presente).
    public let intelligenceUnavailableReason: String?
}

/// Orchestra estrazione feature → scoring euristico → narrativa Apple Intelligence
/// per una playlist. Actor coerente con l'architettura del progetto (un solo
/// accesso alla volta, come `IndexService`/`AlbumService`).
public actor PlaylistAnalysisService {
    private let db: AppDatabase
    private let extractor: any PlaylistFeatureExtractor
    private let scorer: any PlaylistScorer

    public init(
        db: AppDatabase,
        extractor: any PlaylistFeatureExtractor = MetadataFeatureExtractor(),
        scorer: any PlaylistScorer = HeuristicPlaylistScorer()
    ) {
        self.db = db
        self.extractor = extractor
        self.scorer = scorer
    }

    /// Analizza i brani di una playlist (nell'ordine di `PlaylistDAO.tracksInPlaylist`,
    /// cioè l'ordine del browser, non necessariamente quello di Music.app — vedi
    /// nota "Anomalie" in evolutive.md sull'ordine playlist).
    public func analyze(playlistID: String, playlistName: String, goal: PlaylistGoal) async throws -> PlaylistAnalysis {
        let (tracks, annotation) = try db.read { db -> ([DBTrack], DBPlaylistAnnotation?) in
            let ts = try PlaylistDAO.tracksInPlaylist(id: playlistID, in: db)
            let ann = try PlaylistDAO.annotation(playlistID: playlistID, in: db)
            return (ts, ann)
        }
        let features = extractor.extract(from: tracks)
        let scores = scorer.score(features)

        let intelligence = Self.makeIntelligence()
        var narrative: PlaylistNarrative?
        var reason: String?
        if await intelligence.isAvailable {
            do {
                let input = PlaylistNarrationInput(
                    playlistName: playlistName, features: features, scores: scores, goal: goal,
                    userDescription: annotation?.playlistDescription ?? "",
                    desiredResult: annotation?.desiredResult ?? "",
                    trackSample: Self.trackSample(tracks))
                narrative = try await intelligence.narrate(input)
            } catch {
                reason = error.localizedDescription
            }
        } else {
            reason = "Apple Intelligence non disponibile su questo Mac (richiede macOS 26+ con Apple Intelligence abilitata)"
        }
        return PlaylistAnalysis(
            features: features, scores: scores, narrative: narrative, intelligenceUnavailableReason: reason)
    }

    /// Campione dei brani ("Titolo — Artista") nell'ordine attuale, cap a 60 righe
    /// per non sforare il contesto ridotto del modello on-device.
    private static func trackSample(_ tracks: [DBTrack]) -> [String] {
        tracks.prefix(60).map { t in
            let name = t.name.isEmpty ? "(senza titolo)" : t.name
            return t.artist.isEmpty ? name : "\(name) — \(t.artist)"
        }
    }

    private static func makeIntelligence() -> any PlaylistIntelligence {
        if #available(macOS 26, *) {
            return FoundationModelsIntelligence()
        }
        return UnavailableIntelligence()
    }
}
