import Foundation
import Persistence
import GRDB

/// Gestisce le proposte di scrittura staged dal server MCP.
///
/// Un agente AI non scrive mai direttamente su Music: deposita una proposta
/// (`create`) che l'utente rivede e approva in UI. All'approvazione (`apply`) la
/// proposta viene applicata via `MetadataWriteService.writeBatch`, quindi passa
/// dallo stesso canale audit/undo delle modifiche manuali.
public actor MCPProposalService {

    private let db: AppDatabase
    private let writeService: MetadataWriteService

    public init(db: AppDatabase, writeService: MetadataWriteService) {
        self.db = db
        self.writeService = writeService
    }

    // ── Tipi di presentazione ────────────────────────────────────────────────

    /// Proposta con gli item già decodificati e lo snapshot "prima" per l'anteprima.
    public struct Proposal: Sendable, Identifiable {
        public let id: String
        public let createdAt: Date
        public let source: String
        public let rationale: String
        public let items: [Item]

        public struct Item: Sendable, Identifiable {
            public var id: String { persistentID }
            public let persistentID: String
            public let update: TrackMetadataUpdate
            public let before: DBTrack?
        }
    }

    // ── Creazione (dal tool MCP) ─────────────────────────────────────────────

    /// Registra una proposta pending. Ritorna l'id della proposta.
    @discardableResult
    public func create(
        updates: [(pid: String, update: TrackMetadataUpdate)],
        rationale: String,
        source: String = "mcp"
    ) throws -> String {
        let proposalID = UUID().uuidString
        let items: [DBProposalItem] = try updates.map { u in
            let json = try Self.encode(u.update)
            return DBProposalItem(proposalID: proposalID, persistentID: u.pid, updateJSON: json)
        }
        try db.write { db in
            _ = try ProposalDAO.insert(
                DBProposal(id: proposalID, source: source, rationale: rationale),
                items: items, in: db
            )
        }
        return proposalID
    }

    // ── Lettura (per la UI) ──────────────────────────────────────────────────

    public func pendingCount() throws -> Int {
        try db.read { try ProposalDAO.countPending(in: $0) }
    }

    public func pending() throws -> [Proposal] {
        try db.read { db in
            try ProposalDAO.fetch(status: "pending", in: db).map { p in
                let items = try ProposalDAO.items(proposalID: p.id, in: db).map { item -> Proposal.Item in
                    let update = try Self.decode(item.updateJSON)
                    let before = try TrackDAO.fetch(persistentID: item.persistentID, in: db)
                    return .init(persistentID: item.persistentID, update: update, before: before)
                }
                return Proposal(id: p.id, createdAt: p.createdAt, source: p.source,
                                rationale: p.rationale, items: items)
            }
        }
    }

    // ── Decisione ────────────────────────────────────────────────────────────

    /// Applica la proposta via il canale di scrittura ufficiale e la segna applicata.
    @discardableResult
    public func apply(proposalID: String) async throws -> WriteResult {
        let items = try db.read { try ProposalDAO.items(proposalID: proposalID, in: $0) }
        guard !items.isEmpty else {
            throw MCPProposalError.notFound(proposalID)
        }
        let batch: [(TrackMetadataUpdate, String)] = try items.map {
            (try Self.decode($0.updateJSON), $0.persistentID)
        }
        let result = try await writeService.writeBatch(batch)
        try db.write { try ProposalDAO.markApplied(id: proposalID, batchID: result.batchID, in: $0) }
        return result
    }

    public func reject(proposalID: String) throws {
        try db.write { try ProposalDAO.markRejected(id: proposalID, in: $0) }
    }

    /// Annulla un batch già applicato (ripristina i valori precedenti via il
    /// servizio di scrittura). Usato dal tool MCP `undo_batch`.
    public func undo(batchID: String) async throws -> WriteResult {
        try await writeService.undo(batchID: batchID)
    }

    // ── (De)serializzazione TrackMetadataUpdate ──────────────────────────────

    private static func encode(_ update: TrackMetadataUpdate) throws -> String {
        let data = try JSONEncoder().encode(update)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decode(_ json: String) throws -> TrackMetadataUpdate {
        try JSONDecoder().decode(TrackMetadataUpdate.self, from: Data(json.utf8))
    }
}

public enum MCPProposalError: Error, Sendable {
    case notFound(String)
}
