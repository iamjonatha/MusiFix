import Foundation
import Persistence

/// Un brano candidato all'integrazione, con la motivazione del modello.
public struct SuggestedAddition: Sendable, Identifiable {
    public let track: DBTrack
    public let reason: String
    public var id: String { track.persistentID }
}

/// Esito della fase "integrazioni": verdetto testuale + candidati proposti.
public struct AdditionSuggestions: Sendable {
    public let verdict: String
    public let additions: [SuggestedAddition]
}

/// Esito della fase "ordine": sequenza proposta (solo a video) + motivazione globale.
public struct OrderSuggestion: Sendable {
    public let rationale: String
    public let orderedTracks: [DBTrack]
}

/// Riferimento leggero a una playlist coinvolta nella riorganizzazione.
public struct PlaylistRef: Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Uno spostamento proposto: un brano da una playlist a un'altra, con motivazione.
public struct SuggestedMove: Sendable, Identifiable {
    public let track: DBTrack
    public let fromID: String
    public let fromName: String
    public let toID: String
    public let toName: String
    public let reason: String
    public var id: String { "\(track.persistentID)|\(fromID)|\(toID)" }
}

/// Esito della riorganizzazione multi-playlist: sintesi + spostamenti proposti.
public struct ReorganizationSuggestions: Sendable {
    public let summary: String
    public let moves: [SuggestedMove]
}

/// Analisi avanzata via LLM cloud (Fase 2 evolutiva). A differenza di
/// `PlaylistAnalysisService` (euristiche + Apple Intelligence on-device), qui il
/// modello vede i brani reali e un pool di candidati dalla libreria, così da
/// suggerire integrazioni concrete e un ordinamento. Le integrazioni vengono
/// applicate solo dopo conferma dell'utente (dalla UI, via bridge); l'ordine è
/// solo a video. Client costruito on-demand dalla configurazione salvata.
public actor AdvancedPlaylistAnalysisService {
    private let db: AppDatabase
    private let clientProvider: @Sendable () -> (any LLMClient)?

    public init(
        db: AppDatabase,
        clientProvider: @escaping @Sendable () -> (any LLMClient)? = {
            LLMConfigStore.currentConfig().map { HTTPLLMClient(config: $0) }
        }
    ) {
        self.db = db
        self.clientProvider = clientProvider
    }

    public var isConfigured: Bool { clientProvider() != nil }

    // ── Fase A: integrazioni ──────────────────────────────────────────────────

    public func suggestAdditions(playlistID: String, playlistName: String) async throws -> AdditionSuggestions {
        guard let client = clientProvider() else { throw Self.notConfigured }

        let (tracks, annotation) = try db.read { db -> ([DBTrack], DBPlaylistAnnotation?) in
            (try PlaylistDAO.tracksInPlaylist(id: playlistID, in: db),
             try PlaylistDAO.annotation(playlistID: playlistID, in: db))
        }
        let topGenres = Self.topGenres(tracks, max: 5)
        let candidates = try db.read { db in
            try PlaylistDAO.candidateTracks(
                forPlaylistID: playlistID, genres: topGenres, limit: 150, in: db)
        }
        guard !candidates.isEmpty else {
            return AdditionSuggestions(verdict: "Nessun brano candidato affine trovato in libreria.", additions: [])
        }

        let user = Self.additionsPrompt(
            playlistName: playlistName,
            description: annotation?.playlistDescription ?? "",
            desiredResult: annotation?.desiredResult ?? "",
            tracks: tracks, candidates: candidates)
        let raw = try await client.complete(system: Self.additionsSystem, user: user, maxTokens: 2048)
        let parsed = try Self.parseAdditions(raw)

        let additions: [SuggestedAddition] = parsed.additions.compactMap { item in
            guard item.n >= 1, item.n <= candidates.count else { return nil }
            return SuggestedAddition(track: candidates[item.n - 1], reason: item.reason)
        }
        return AdditionSuggestions(verdict: parsed.verdict, additions: additions)
    }

    // ── Fase B: ordine (sull'insieme finale, integrazioni comprese) ───────────

    public func suggestOrder(
        playlistID: String, playlistName: String, finalTracks: [DBTrack]
    ) async throws -> OrderSuggestion {
        guard let client = clientProvider() else { throw Self.notConfigured }
        let annotation = try db.read { db in try PlaylistDAO.annotation(playlistID: playlistID, in: db) }
        let capped = Array(finalTracks.prefix(150))

        let user = Self.orderPrompt(
            playlistName: playlistName,
            desiredResult: annotation?.desiredResult ?? "",
            tracks: capped)
        let raw = try await client.complete(system: Self.orderSystem, user: user, maxTokens: 2048)
        let parsed = try Self.parseOrder(raw)

        // Mappa gli indici (1-based) validati, de-dup, poi accoda gli eventuali mancanti.
        var used = Set<Int>()
        var ordered: [DBTrack] = []
        for idx in parsed.order where idx >= 1 && idx <= capped.count && !used.contains(idx) {
            used.insert(idx)
            ordered.append(capped[idx - 1])
        }
        for (i, t) in capped.enumerated() where !used.contains(i + 1) { ordered.append(t) }
        return OrderSuggestion(rationale: parsed.rationale, orderedTracks: ordered)
    }

    // ── Fase C: riorganizzazione multi-playlist (punto 6) ────────────────────

    /// Dato un criterio logico e un insieme di playlist, propone spostamenti di brani
    /// tra le playlist. Ogni spostamento è confermato dall'utente (add su destinazione
    /// + remove da origine, via bridge). Cap globale di 300 brani per limitare il contesto.
    public func suggestReorganization(
        playlists: [PlaylistRef], criterion: String
    ) async throws -> ReorganizationSuggestions {
        guard let client = clientProvider() else { throw Self.notConfigured }
        guard playlists.count >= 2 else {
            throw MusiFixError.appleScriptError("La riorganizzazione richiede almeno 2 playlist.")
        }

        // Carica tracce + annotazioni per ogni playlist.
        struct Loaded { let ref: PlaylistRef; let desired: String; let tracks: [DBTrack] }
        let loaded: [Loaded] = try db.read { db in
            try playlists.map { ref in
                let ts = try PlaylistDAO.tracksInPlaylist(id: ref.id, in: db)
                let ann = try PlaylistDAO.annotation(playlistID: ref.id, in: db)
                return Loaded(ref: ref, desired: ann?.desiredResult ?? "", tracks: ts)
            }
        }

        // Numerazione globale delle voci (playlist, brano). Un brano presente in più
        // playlist selezionate compare più volte, così può essere spostato per occorrenza.
        struct Entry { let track: DBTrack; let fromIdx: Int }
        var entries: [Entry] = []
        outer: for (pIdx, item) in loaded.enumerated() {
            for t in item.tracks {
                entries.append(Entry(track: t, fromIdx: pIdx))
                if entries.count >= 300 { break outer }
            }
        }

        let user = Self.reorganizePrompt(criterion: criterion, playlists: loaded.map { ($0.ref.name, $0.desired) },
                                         entries: entries.map { ($0.track, $0.fromIdx) })
        let raw = try await client.complete(system: Self.reorganizeSystem, user: user, maxTokens: 3000)
        let parsed = try Self.parseMoves(raw)

        let moves: [SuggestedMove] = parsed.moves.compactMap { m in
            guard m.t >= 1, m.t <= entries.count, m.to >= 1, m.to <= loaded.count else { return nil }
            let entry = entries[m.t - 1]
            let toIdx = m.to - 1
            guard toIdx != entry.fromIdx else { return nil }   // stessa playlist: non è uno spostamento
            return SuggestedMove(
                track: entry.track,
                fromID: loaded[entry.fromIdx].ref.id, fromName: loaded[entry.fromIdx].ref.name,
                toID: loaded[toIdx].ref.id, toName: loaded[toIdx].ref.name,
                reason: m.reason)
        }
        return ReorganizationSuggestions(summary: parsed.summary, moves: moves)
    }

    // ── Helper dati ───────────────────────────────────────────────────────────

    private static var notConfigured: MusiFixError {
        .appleScriptError("Nessun provider AI configurato. Imposta provider e chiave API.")
    }

    private static func topGenres(_ tracks: [DBTrack], max: Int) -> [String] {
        var counts: [String: Int] = [:]
        for t in tracks {
            let g = t.genre.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty { counts[g, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(max).map(\.key)
    }

    private static func line(_ t: DBTrack) -> String {
        var s = t.name.isEmpty ? "(senza titolo)" : t.name
        if !t.artist.isEmpty { s += " — \(t.artist)" }
        var meta: [String] = []
        if !t.genre.isEmpty { meta.append(t.genre) }
        if t.year > 0 { meta.append(String(t.year)) }
        if !meta.isEmpty { s += " [\(meta.joined(separator: ", "))]" }
        return s
    }

    // ── Prompt ────────────────────────────────────────────────────────────────

    private static let additionsSystem = """
        Sei un curatore musicale. Ricevi una playlist (con descrizione e risultato \
        desiderato dall'utente) e un elenco numerato di brani candidati dalla libreria \
        dell'utente. Suggerisci SOLO brani presenti tra i candidati, indicandone il \
        numero, per avvicinare la playlist al risultato desiderato. Rispondi ESCLUSIVAMENTE \
        in JSON valido, senza testo fuori dal JSON, con questa forma:
        {"verdict": "breve valutazione in italiano", "additions": [{"n": <numero candidato>, "reason": "motivo conciso in italiano"}]}
        Includi al massimo 15 integrazioni, le più pertinenti. Se nessuna è utile, additions sia [].
        """

    private static func additionsPrompt(
        playlistName: String, description: String, desiredResult: String,
        tracks: [DBTrack], candidates: [DBTrack]
    ) -> String {
        var out = ["Playlist: \(playlistName)"]
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { out.append("Descrizione: \(d)") }
        let r = desiredResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { out.append("Risultato desiderato: \(r)") }
        out.append("\nBrani attuali (\(tracks.count)):")
        for t in tracks.prefix(100) { out.append("- \(line(t))") }
        out.append("\nCandidati dalla libreria (scegli per numero):")
        for (i, c) in candidates.enumerated() { out.append("\(i + 1). \(line(c))") }
        return out.joined(separator: "\n")
    }

    private static let orderSystem = """
        Sei un curatore musicale. Ricevi un elenco numerato di brani di una playlist e il \
        risultato desiderato dall'utente. Proponi l'ordine di ascolto migliore riordinando \
        i numeri dei brani. Rispondi ESCLUSIVAMENTE in JSON valido, senza testo fuori dal \
        JSON, con questa forma:
        {"order": [<numeri dei brani nel nuovo ordine>], "rationale": "motivo conciso in italiano"}
        L'array order deve contenere ogni numero una sola volta.
        """

    private static func orderPrompt(playlistName: String, desiredResult: String, tracks: [DBTrack]) -> String {
        var out = ["Playlist: \(playlistName)"]
        let r = desiredResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { out.append("Risultato desiderato: \(r)") }
        out.append("\nBrani (numerati):")
        for (i, t) in tracks.enumerated() { out.append("\(i + 1). \(line(t))") }
        return out.joined(separator: "\n")
    }

    private static let reorganizeSystem = """
        Sei un curatore musicale. Ricevi un insieme di playlist numerate (con il loro \
        risultato desiderato) e un elenco numerato di brani, ciascuno con la playlist di \
        appartenenza attuale. Applicando il criterio logico indicato dall'utente, proponi \
        di spostare i brani nella playlist più adatta tra quelle fornite. Proponi uno \
        spostamento SOLO se la playlist di destinazione è diversa da quella attuale. \
        Rispondi ESCLUSIVAMENTE in JSON valido, senza testo fuori dal JSON, con questa forma:
        {"summary": "sintesi in italiano", "moves": [{"t": <numero brano>, "to": <numero playlist destinazione>, "reason": "motivo conciso in italiano"}]}
        """

    private static func reorganizePrompt(
        criterion: String, playlists: [(name: String, desired: String)],
        entries: [(track: DBTrack, fromIdx: Int)]
    ) -> String {
        var out = ["Criterio: \(criterion.trimmingCharacters(in: .whitespacesAndNewlines))", "", "Playlist:"]
        for (i, p) in playlists.enumerated() {
            var s = "\(i + 1). \(p.name)"
            let d = p.desired.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { s += " — desiderato: \(d)" }
            out.append(s)
        }
        out.append("\nBrani (numero. titolo — artista [genere, anno] · attuale: playlist N):")
        for (i, e) in entries.enumerated() {
            out.append("\(i + 1). \(line(e.track)) · attuale: playlist \(e.fromIdx + 1)")
        }
        return out.joined(separator: "\n")
    }

    // ── Parsing JSON (tollerante a code-fence e testo attorno) ────────────────

    private struct AdditionsDTO: Decodable {
        struct Item: Decodable { let n: Int; let reason: String? }
        let verdict: String?
        let additions: [Item]?
    }
    private struct OrderDTO: Decodable {
        let order: [Int]?
        let rationale: String?
    }
    private struct MovesDTO: Decodable {
        struct Item: Decodable { let t: Int; let to: Int; let reason: String? }
        let summary: String?
        let moves: [Item]?
    }

    private static func parseAdditions(_ raw: String) throws -> (verdict: String, additions: [(n: Int, reason: String)]) {
        let dto = try decode(AdditionsDTO.self, from: raw)
        let items = (dto.additions ?? []).map { (n: $0.n, reason: $0.reason ?? "") }
        return (dto.verdict ?? "", items)
    }

    private static func parseOrder(_ raw: String) throws -> (order: [Int], rationale: String) {
        let dto = try decode(OrderDTO.self, from: raw)
        return (dto.order ?? [], dto.rationale ?? "")
    }

    private static func parseMoves(_ raw: String) throws -> (summary: String, moves: [(t: Int, to: Int, reason: String)]) {
        let dto = try decode(MovesDTO.self, from: raw)
        let items = (dto.moves ?? []).map { (t: $0.t, to: $0.to, reason: $0.reason ?? "") }
        return (dto.summary ?? "", items)
    }

    /// Isola il blocco JSON (dal primo `{` all'ultimo `}`) e lo decodifica.
    private static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw MusiFixError.appleScriptError("Risposta AI non in formato JSON atteso:\n\(raw.prefix(300))")
        }
        let jsonString = String(raw[start...end])
        guard let data = jsonString.data(using: .utf8) else {
            throw MusiFixError.appleScriptError("Risposta AI non decodificabile")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MusiFixError.appleScriptError("Impossibile interpretare la risposta AI: \(error.localizedDescription)")
        }
    }
}
