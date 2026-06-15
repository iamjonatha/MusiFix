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
