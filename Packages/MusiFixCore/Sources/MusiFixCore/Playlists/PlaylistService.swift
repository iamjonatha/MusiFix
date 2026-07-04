import Foundation

/// Gestione delle playlist utente di Music.app: elenco (con cartelle) e aggiunta
/// di brani con de-duplicazione. Serializza l'accesso al bridge come gli altri servizi.
public actor PlaylistService {
    private let bridge: any AppleMusicBridge

    public init(bridge: any AppleMusicBridge) {
        self.bridge = bridge
    }

    /// Alberatura piatta delle playlist modificabili (playlist normali + cartelle),
    /// con `parentID` per ricostruire la gerarchia lato UI.
    public func playlistTree() async throws -> [MusicPlaylistNode] {
        try await bridge.userPlaylistTree()
    }

    /// Aggiunge i brani alla playlist indicata, saltando quelli già presenti.
    public func addTracks(_ pids: [String], toPlaylistID playlistID: String) async throws -> PlaylistAddResult {
        guard !pids.isEmpty else { return PlaylistAddResult(added: 0, skipped: 0, failed: 0) }
        return try await bridge.addTracks(pids, toPlaylistID: playlistID)
    }
}
