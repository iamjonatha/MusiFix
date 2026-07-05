import Foundation

/// Protocollo che astrae l'accesso a Music.app.
/// Le due implementazioni concrete (ScriptingBridge e NSAppleScript) sono
/// selezionabili a runtime; entrambe sono serializzate da `MusicActor`.
public protocol AppleMusicBridge: Sendable {
    /// Enumera tutti i brani della libreria.
    func allTracks() async throws -> [Track]

    /// Legge i metadati aggiornati di un singolo track.
    func trackMetadata(persistentID: String) async throws -> Track

    /// Applica le modifiche di metadati. Solo i campi non-nil vengono scritti.
    func updateMetadata(_ update: TrackMetadataUpdate, persistentID: String) async throws

    /// Imposta la copertina come dati JPEG/PNG.
    func setArtwork(_ data: Data, persistentID: String) async throws

    /// Legge la copertina come PNG. Nil se assente.
    func artwork(persistentID: String) async throws -> Data?

    /// Rimuove il track dalla libreria Music. Il file fisico NON viene toccato.
    func deleteTrack(persistentID: String) async throws

    /// Seleziona e mostra il track in Music.app (porta Music in primo piano).
    func revealInMusic(persistentID: String) async throws

    /// Persistent ID di tutti i brani che appartengono ad almeno una playlist
    /// "normale" dell'utente (escluse smart playlist, cartelle e playlist speciali).
    func tracksInRegularPlaylists() async throws -> Set<String>

    /// Alberatura delle playlist utente modificabili (playlist normali + cartelle),
    /// con relazione di appartenenza alle cartelle via `parentID`.
    func userPlaylistTree() async throws -> [MusicPlaylistNode]

    /// Aggiunge i brani (per persistentID) alla playlist indicata, saltando i duplicati.
    func addTracks(_ pids: [String], toPlaylistID playlistID: String) async throws -> PlaylistAddResult

    /// Garantisce l'esistenza di una playlist (dato nome), eventualmente dentro una
    /// cartella (creata se assente). Ritorna il persistentID della playlist.
    func ensurePlaylist(named name: String, inFolder folder: String?) async throws -> String

    /// Appartenenza completa: per ogni playlist normale/cartella dell'utente
    /// restituisce nodo + elenco dei persistentID contenuti (vuoto per le cartelle).
    func playlistMembership() async throws -> [PlaylistMembership]
}

// ── Modelli playlist ───────────────────────────────────────────────────────────

/// Nodo dell'alberatura playlist: una playlist normale o una cartella.
public struct MusicPlaylistNode: Sendable, Identifiable, Hashable {
    public let id: String            // persistentID
    public let name: String
    public let isFolder: Bool
    public let parentID: String?     // persistentID della cartella contenitore, se presente

    public init(id: String, name: String, isFolder: Bool, parentID: String?) {
        self.id = id; self.name = name; self.isFolder = isFolder; self.parentID = parentID
    }
}

/// Nodo playlist con l'elenco completo dei brani contenuti (per la Vista Playlist
/// e le playlist-per-brano). Le cartelle hanno `trackIDs` vuoto.
public struct PlaylistMembership: Sendable {
    public let node: MusicPlaylistNode
    public let trackIDs: [String]

    public init(node: MusicPlaylistNode, trackIDs: [String]) {
        self.node = node; self.trackIDs = trackIDs
    }
}

/// Esito di un'aggiunta di brani a playlist.
public struct PlaylistAddResult: Sendable {
    public let added: Int      // brani effettivamente aggiunti
    public let skipped: Int    // già presenti in playlist
    public let failed: Int     // non trovati / errore in aggiunta

    public init(added: Int, skipped: Int, failed: Int) {
        self.added = added; self.skipped = skipped; self.failed = failed
    }
}

// Default: le implementazioni che non supportano le playlist (es. AppleScript) sollevano.
public extension AppleMusicBridge {
    func userPlaylistTree() async throws -> [MusicPlaylistNode] {
        throw MusiFixError.appleScriptError("Gestione playlist non supportata da questo bridge")
    }
    func addTracks(_ pids: [String], toPlaylistID playlistID: String) async throws -> PlaylistAddResult {
        throw MusiFixError.appleScriptError("Aggiunta a playlist non supportata da questo bridge")
    }
    func ensurePlaylist(named name: String, inFolder folder: String?) async throws -> String {
        throw MusiFixError.appleScriptError("Creazione playlist non supportata da questo bridge")
    }
    func playlistMembership() async throws -> [PlaylistMembership] {
        throw MusiFixError.appleScriptError("Membership playlist non supportata da questo bridge")
    }
}

/// Seleziona l'implementazione ottimale disponibile a runtime.
public enum AppleMusicBridgeFactory {
    public static func makeBridge() -> any AppleMusicBridge {
        // Prova ScriptingBridge (primaria)
        if let sb = ScriptingBridgeImpl() {
            return sb
        }
        // Fallback: NSAppleScript
        return NSAppleScriptImpl()
    }
}
