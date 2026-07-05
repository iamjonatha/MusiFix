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

    /// Cartella e playlist dedicate ai brani "da verificare".
    public static let verifyFolder = "WORK"
    public static let verifyPlaylist = "ToCheck"

    /// Segna i brani come "da verificare": garantisce la playlist WORK/ToCheck
    /// (creandola se assente) e vi aggiunge i brani con de-duplicazione.
    public func markForVerification(_ pids: [String]) async throws -> PlaylistAddResult {
        guard !pids.isEmpty else { return PlaylistAddResult(added: 0, skipped: 0, failed: 0) }
        let playlistID = try await bridge.ensurePlaylist(
            named: Self.verifyPlaylist, inFolder: Self.verifyFolder)
        return try await bridge.addTracks(pids, toPlaylistID: playlistID)
    }

    /// Membership completa (playlist → brani), per la scansione della Vista Playlist.
    public func membership() async throws -> [PlaylistMembership] {
        try await bridge.playlistMembership()
    }
}
