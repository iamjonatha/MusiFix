import Foundation
import Persistence
import GRDB
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "MCPServerService")

/// Server MCP embedded nell'app. Espone la libreria (ricerca brani, playlist,
/// statistiche) in sola lettura e accetta proposte di scrittura metadati che
/// restano in attesa di approvazione utente (o applicate subito se `autoApply`).
///
/// Trasporto: JSON-RPC 2.0 su HTTP "Streamable" (loopback). Attivabile/spegnibile
/// dalla UI: a server fermo nessuna porta è aperta.
public actor MCPServerService {

    public static let protocolVersion = "2025-06-18"
    public static let defaultPort: UInt16 = 8765
    /// Tetto di sicurezza sul numero di brani per singola proposta di scrittura.
    public static let maxProposalItems = 500

    private let db: AppDatabase
    private let proposals: MCPProposalService

    private var httpServer: MCPHTTPServer?
    private var token: String?
    private var autoApply = false

    public private(set) var isRunning = false
    public private(set) var port: UInt16 = MCPServerService.defaultPort

    public init(db: AppDatabase, proposals: MCPProposalService) {
        self.db = db
        self.proposals = proposals
    }

    // ── Ciclo di vita ────────────────────────────────────────────────────────

    /// Avvia il server. `token` opzionale: se valorizzato, ogni richiesta deve
    /// portare `Authorization: Bearer <token>`. `autoApply`: se true le proposte
    /// di scrittura vengono applicate immediatamente invece di attendere l'approvazione.
    public func start(port: UInt16, token: String?, autoApply: Bool) throws {
        stopInternal()
        self.port = port
        self.token = (token?.isEmpty ?? true) ? nil : token
        self.autoApply = autoApply
        let server = MCPHTTPServer(port: port) { [weak self] req in
            guard let self else {
                return .init(status: 503, headers: [:], body: Data())
            }
            return await self.handle(req)
        }
        try server.start()
        httpServer = server
        isRunning = true
    }

    public func stop() { stopInternal() }

    private func stopInternal() {
        httpServer?.stop()
        httpServer = nil
        isRunning = false
    }

    // ── Handling HTTP → JSON-RPC ─────────────────────────────────────────────

    private func handle(_ req: MCPHTTPServer.Request) async -> MCPHTTPServer.Response {
        // Autenticazione bearer opzionale.
        if let token {
            let auth = req.headers["authorization"] ?? ""
            guard auth == "Bearer \(token)" else {
                return json(401, ["error": "unauthorized"])
            }
        }
        guard req.method == "POST" else {
            return .init(status: 405, headers: ["Allow": "POST"], body: Data())
        }
        guard let message = try? JSONValue.parse(req.body) else {
            return rpc(id: .null, error: (-32700, "Parse error"))
        }
        return await dispatch(message)
    }

    private func dispatch(_ message: JSONValue) async -> MCPHTTPServer.Response {
        let id = message["id"]
        let method = message["method"]?.stringValue ?? ""
        let params = message["params"]

        // Notifiche (senza id): nessun corpo di risposta.
        guard let id else {
            return .init(status: 202, headers: [:], body: Data())
        }

        switch method {
        case "initialize":
            return rpc(id: id, result: initializeResult(params))
        case "tools/list":
            return rpc(id: id, result: toolsListResult())
        case "tools/call":
            return await handleToolCall(id: id, params: params)
        case "ping":
            return rpc(id: id, result: [:])
        default:
            return rpc(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    // ── initialize / tools/list ──────────────────────────────────────────────

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue ?? Self.protocolVersion
        return [
            "protocolVersion": .string(requested),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "MusiFix", "version": "1.0.0"],
            "instructions": "Libreria musicale MusiFix. Usa search_tracks/list_playlists/get_playlist/library_stats per leggere. Le scritture (propose_metadata_update) restano in attesa di approvazione dell'utente nell'app."
        ]
    }

    private func toolsListResult() -> JSONValue {
        ["tools": .array(MCPTools.all)]
    }

    // ── tools/call ───────────────────────────────────────────────────────────

    private func handleToolCall(id: JSONValue, params: JSONValue?) async -> MCPHTTPServer.Response {
        guard let name = params?["name"]?.stringValue else {
            return rpc(id: id, error: (-32602, "Parametro 'name' mancante"))
        }
        let args = params?["arguments"] ?? .object([:])
        do {
            let result: JSONValue
            switch name {
            case "search_tracks":            result = try toolSearchTracks(args)
            case "list_playlists":           result = try toolListPlaylists(args)
            case "get_playlist":             result = try toolGetPlaylist(args)
            case "library_stats":            result = try toolLibraryStats()
            case "propose_metadata_update":  result = try await toolProposeUpdate(args)
            case "undo_batch":               result = try await toolUndoBatch(args)
            default:
                return rpc(id: id, error: (-32601, "Tool sconosciuto: \(name)"))
            }
            return rpc(id: id, result: result)
        } catch {
            log.error("Tool \(name) fallito: \(error.localizedDescription)")
            return rpc(id: id, result: toolError(error.localizedDescription))
        }
    }

    // ── Tool: read ───────────────────────────────────────────────────────────

    private func toolSearchTracks(_ args: JSONValue) throws -> JSONValue {
        let limit = min(max(args["limit"]?.intValue ?? 100, 1), 500)
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let tracks = try db.read { db in
            try TrackDAO.searchAdvanced(
                text: args["query"]?.stringValue,
                artist: args["artist"]?.stringValue,
                album: args["album"]?.stringValue,
                genre: args["genre"]?.stringValue,
                year: args["year"]?.intValue,
                yearFrom: args["yearFrom"]?.intValue,
                yearTo: args["yearTo"]?.intValue,
                limit: limit, offset: offset, in: db
            )
        }
        return toolResult([
            "count": .int(tracks.count),
            "tracks": .array(tracks.map(Self.trackJSON))
        ])
    }

    private func toolListPlaylists(_ args: JSONValue) throws -> JSONValue {
        let includeFolders = args["includeFolders"]?.boolValue ?? false
        let playlists = try db.read { db -> [JSONValue] in
            try PlaylistDAO.fetchPlaylists(in: db)
                .filter { includeFolders || !$0.isFolder }
                .map { p in
                    let count = try PlaylistDAO.trackCount(id: p.id, in: db)
                    let ann = try PlaylistDAO.annotation(playlistID: p.id, in: db)
                    return JSONValue.object([
                        "id": .string(p.id),
                        "name": .string(p.name),
                        "isFolder": .bool(p.isFolder),
                        "trackCount": .int(count),
                        "description": .string(ann?.playlistDescription ?? ""),
                        "desiredResult": .string(ann?.desiredResult ?? "")
                    ])
                }
        }
        return toolResult(["count": .int(playlists.count), "playlists": .array(playlists)])
    }

    private func toolGetPlaylist(_ args: JSONValue) throws -> JSONValue {
        let idArg = args["id"]?.stringValue
        let nameArg = args["name"]?.stringValue
        let result = try db.read { db -> JSONValue? in
            let playlists = try PlaylistDAO.fetchPlaylists(in: db)
            let match: DBPlaylist? = {
                if let idArg { return playlists.first { $0.id == idArg } }
                if let nameArg {
                    return playlists.first { $0.name.compare(nameArg, options: .caseInsensitive) == .orderedSame }
                }
                return nil
            }()
            guard let pl = match else { return nil }
            let tracks = try PlaylistDAO.tracksInPlaylist(id: pl.id, in: db)
            let ann = try PlaylistDAO.annotation(playlistID: pl.id, in: db)
            return JSONValue.object([
                "id": .string(pl.id),
                "name": .string(pl.name),
                "description": .string(ann?.playlistDescription ?? ""),
                "desiredResult": .string(ann?.desiredResult ?? ""),
                "trackCount": .int(tracks.count),
                "tracks": .array(tracks.map(Self.trackJSON))
            ])
        }
        guard let result else {
            return toolError("Playlist non trovata. Specifica 'id' o 'name' esatto (usa list_playlists).")
        }
        return toolResult(result)
    }

    private func toolLibraryStats() throws -> JSONValue {
        try db.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            return toolResult([
                "totalTracks": .int(try count("SELECT COUNT(*) FROM track")),
                "distinctArtists": .int(try count("SELECT COUNT(DISTINCT artistNormalized) FROM track WHERE artist != ''")),
                "distinctAlbums": .int(try count("SELECT COUNT(DISTINCT albumNormalized) FROM track WHERE album != ''")),
                "distinctGenres": .int(try count("SELECT COUNT(DISTINCT genreNormalized) FROM track WHERE genre != ''")),
                "cloudOnly": .int(try count("SELECT COUNT(*) FROM track WHERE isCloudOnly = 1")),
                "missingYear": .int(try count("SELECT COUNT(*) FROM track WHERE year = 0")),
                "playlists": .int(try count("SELECT COUNT(*) FROM playlist WHERE isFolder = 0"))
            ])
        }
    }

    // ── Tool: write (staged) ─────────────────────────────────────────────────

    private func toolProposeUpdate(_ args: JSONValue) async throws -> JSONValue {
        let rationale = args["rationale"]?.stringValue ?? ""
        var updates: [(pid: String, update: TrackMetadataUpdate)] = []

        if let items = args["items"]?.arrayValue {
            for item in items {
                guard let pid = item["persistentID"]?.stringValue else { continue }
                let update = Self.buildUpdate(from: item["fields"] ?? item)
                if !update.changedFields.isEmpty { updates.append((pid, update)) }
            }
        } else {
            let fields = args["fields"] ?? args
            let update = Self.buildUpdate(from: fields)
            var pids: [String] = []
            if let single = args["persistentID"]?.stringValue { pids = [single] }
            else if let arr = args["persistentIDs"]?.arrayValue { pids = arr.compactMap { $0.stringValue } }
            for pid in pids where !update.changedFields.isEmpty { updates.append((pid, update)) }
        }

        guard !updates.isEmpty else {
            return toolError("Nessun aggiornamento valido: specifica almeno un persistentID e un campo da modificare.")
        }
        guard updates.count <= Self.maxProposalItems else {
            return toolError("Troppi brani (\(updates.count)); massimo \(Self.maxProposalItems) per proposta.")
        }

        // Verifica che i brani esistano nell'indice.
        let pidsToCheck = updates.map { $0.pid }
        let known = try db.read { db -> [String: Bool] in
            var m: [String: Bool] = [:]
            for pid in pidsToCheck where m[pid] == nil {
                m[pid] = (try TrackDAO.fetch(persistentID: pid, in: db)) != nil
            }
            return m
        }
        let valid = updates.filter { known[$0.pid] == true }
        let unknown = updates.filter { known[$0.pid] != true }.map { $0.pid }
        guard !valid.isEmpty else {
            return toolError("Nessuno dei persistentID indicati esiste nell'indice.")
        }

        let proposalID = try await proposals.create(updates: valid, rationale: rationale)

        if autoApply {
            let result = try await proposals.apply(proposalID: proposalID)
            return toolResult([
                "proposalID": .string(proposalID),
                "applied": .bool(true),
                "batchID": .string(result.batchID),
                "succeeded": .int(result.succeeded.count),
                "failed": .int(result.failed.count),
                "unknownIgnored": .array(unknown.map { .string($0) })
            ])
        }
        return toolResult([
            "proposalID": .string(proposalID),
            "applied": .bool(false),
            "stagedItems": .int(valid.count),
            "unknownIgnored": .array(unknown.map { .string($0) }),
            "note": "Proposta in attesa di approvazione nell'app MusiFix (pannello Proposte AI)."
        ])
    }

    private func toolUndoBatch(_ args: JSONValue) async throws -> JSONValue {
        guard let batchID = args["batchID"]?.stringValue, !batchID.isEmpty else {
            return toolError("Parametro 'batchID' mancante.")
        }
        let result = try await proposals.undo(batchID: batchID)
        return toolResult([
            "batchID": .string(batchID),
            "reverted": .int(result.succeeded.count),
            "failed": .int(result.failed.count)
        ])
    }

    // ── Helpers JSON-RPC / MCP ───────────────────────────────────────────────

    private func rpc(id: JSONValue, result: JSONValue) -> MCPHTTPServer.Response {
        json(200, ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func rpc(id: JSONValue, error: (code: Int, message: String)) -> MCPHTTPServer.Response {
        json(200, ["jsonrpc": "2.0", "id": id,
                   "error": ["code": .int(error.code), "message": .string(error.message)]])
    }

    private func json(_ status: Int, _ value: JSONValue) -> MCPHTTPServer.Response {
        .init(status: status, headers: ["Content-Type": "application/json"], body: value.serialized())
    }

    /// Risultato tool MCP: il payload come testo JSON + `structuredContent`.
    private nonisolated func toolResult(_ payload: JSONValue) -> JSONValue {
        ["content": [["type": "text", "text": .string(payload.jsonString)]],
         "structuredContent": payload,
         "isError": false]
    }

    private nonisolated func toolError(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    // ── Serializzazione brano / costruzione update ───────────────────────────

    private static func trackJSON(_ t: DBTrack) -> JSONValue {
        .object([
            "persistentID": .string(t.persistentID),
            "name": .string(t.name),
            "artist": .string(t.artist),
            "albumArtist": .string(t.albumArtist),
            "album": .string(t.album),
            "year": .int(t.year),
            "genre": .string(t.genre),
            "trackNumber": .int(t.trackNumber),
            "trackCount": .int(t.trackCount),
            "discNumber": .int(t.discNumber),
            "discCount": .int(t.discCount),
            "durationSeconds": .double(t.duration),
            "playedCount": .int(t.playedCount),
            "isCloudOnly": .bool(t.isCloudOnly)
        ])
    }

    private static func buildUpdate(from fields: JSONValue) -> TrackMetadataUpdate {
        var u = TrackMetadataUpdate()
        u.name        = fields["name"]?.stringValue
        u.artist      = fields["artist"]?.stringValue
        u.albumArtist = fields["albumArtist"]?.stringValue
        u.album       = fields["album"]?.stringValue
        u.year        = fields["year"]?.intValue
        u.genre       = fields["genre"]?.stringValue
        u.comment     = fields["comment"]?.stringValue
        u.composer    = fields["composer"]?.stringValue
        u.trackNumber = fields["trackNumber"]?.intValue
        u.trackCount  = fields["trackCount"]?.intValue
        u.discNumber  = fields["discNumber"]?.intValue
        u.discCount   = fields["discCount"]?.intValue
        return u
    }
}
