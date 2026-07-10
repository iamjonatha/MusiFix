import Foundation

/// Definizioni (schema) dei tool esposti dal server MCP, per la risposta
/// `tools/list`. La logica è in `MCPServerService`.
enum MCPTools {

    static let all: [JSONValue] = [
        searchTracks, listPlaylists, getPlaylist, libraryStats,
        proposeMetadataUpdate, undoBatch
    ]

    // Annotazioni MCP: readOnlyHint = non modifica lo stato; destructiveHint =
    // effetto potenzialmente distruttivo (i client avvisano l'utente).
    private static func annotations(title: String, readOnly: Bool, destructive: Bool = false) -> JSONValue {
        ["title": .string(title),
         "readOnlyHint": .bool(readOnly),
         "destructiveHint": .bool(destructive)]
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object",
         "properties": .object(properties),
         "required": .array(required.map { .string($0) })]
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }

    // ── Read ─────────────────────────────────────────────────────────────────

    private static let searchTracks: JSONValue = [
        "name": "search_tracks",
        "description": "Cerca brani nella libreria combinando (in AND) filtri opzionali: testo libero (in titolo/artista/album), artista, album, genere, anno o intervallo di anni. Ritorna al massimo 500 brani.",
        "inputSchema": schema([
            "query": prop("string", "Testo libero cercato in titolo, artista e album (sottostringa)."),
            "artist": prop("string", "Filtra per artista (sottostringa)."),
            "album": prop("string", "Filtra per album (sottostringa)."),
            "genre": prop("string", "Filtra per genere (sottostringa)."),
            "year": prop("integer", "Anno di pubblicazione esatto."),
            "yearFrom": prop("integer", "Estremo inferiore intervallo anni (incluso)."),
            "yearTo": prop("integer", "Estremo superiore intervallo anni (incluso)."),
            "limit": prop("integer", "Numero massimo di risultati (1–500, default 100)."),
            "offset": prop("integer", "Offset di paginazione (default 0).")
        ]),
        "annotations": annotations(title: "Cerca brani", readOnly: true)
    ]

    private static let listPlaylists: JSONValue = [
        "name": "list_playlists",
        "description": "Elenca le playlist utente con nome, numero di brani ed eventuale descrizione/obiettivo. Le cartelle sono escluse salvo includeFolders=true.",
        "inputSchema": schema([
            "includeFolders": prop("boolean", "Includi anche le cartelle di playlist (default false).")
        ]),
        "annotations": annotations(title: "Elenca playlist", readOnly: true)
    ]

    private static let getPlaylist: JSONValue = [
        "name": "get_playlist",
        "description": "Restituisce i brani di una playlist nell'ordine della playlist. Indicare 'id' (preferito) oppure 'name' esatto.",
        "inputSchema": schema([
            "id": prop("string", "persistentID della playlist (da list_playlists)."),
            "name": prop("string", "Nome esatto della playlist (case-insensitive), se non si ha l'id.")
        ]),
        "annotations": annotations(title: "Leggi playlist", readOnly: true)
    ]

    private static let libraryStats: JSONValue = [
        "name": "library_stats",
        "description": "Statistiche di sintesi della libreria: totale brani, artisti/album/generi distinti, brani solo-cloud, brani senza anno, numero di playlist.",
        "inputSchema": schema([:]),
        "annotations": annotations(title: "Statistiche libreria", readOnly: true)
    ]

    // ── Write (staged) ───────────────────────────────────────────────────────

    private static let proposeMetadataUpdate: JSONValue = [
        "name": "propose_metadata_update",
        "description": """
            Propone l'aggiornamento dei metadati di uno o più brani. NON scrive \
            subito: crea una proposta che l'utente deve approvare nell'app MusiFix \
            (a meno che l'auto-approvazione sia attiva). Indicare i brani con \
            'persistentID' (singolo) o 'persistentIDs' (lista) + un oggetto 'fields' \
            con i soli campi da cambiare; oppure 'items' con un aggiornamento diverso \
            per brano. Campi ammessi: name, artist, albumArtist, album, year (int), \
            genre, comment, composer, trackNumber, trackCount, discNumber, discCount.
            """,
        "inputSchema": schema([
            "persistentID": prop("string", "persistentID di un singolo brano."),
            "persistentIDs": ["type": "array", "description": "Lista di persistentID a cui applicare gli stessi 'fields'.", "items": ["type": "string"]],
            "fields": ["type": "object", "description": "Campi da modificare (solo quelli presenti vengono cambiati)."],
            "items": ["type": "array", "description": "Alternativa: elenco di { persistentID, fields } con aggiornamenti distinti per brano.", "items": ["type": "object"]],
            "rationale": prop("string", "Motivazione della modifica, mostrata all'utente in fase di approvazione.")
        ]),
        "annotations": annotations(title: "Proponi modifica metadati", readOnly: false, destructive: true)
    ]

    private static let undoBatch: JSONValue = [
        "name": "undo_batch",
        "description": "Annulla un batch di scrittura già applicato, ripristinando i valori precedenti. Richiede il batchID restituito da una proposta applicata.",
        "inputSchema": schema([
            "batchID": prop("string", "Identificativo del batch da annullare.")
        ], required: ["batchID"]),
        "annotations": annotations(title: "Annulla batch", readOnly: false, destructive: true)
    ]
}
