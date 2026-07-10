import GRDB
import Foundation

/// Accesso alle tabelle `mcp_proposal` / `mcp_proposal_item` (migrazione v15).
/// Le proposte sono richieste di scrittura depositate da un agente AI via server
/// MCP e in attesa di approvazione utente.
public enum ProposalDAO {

    /// Inserisce una proposta con i suoi item. Ritorna l'id della proposta.
    @discardableResult
    public static func insert(
        _ proposal: DBProposal,
        items: [DBProposalItem],
        in db: Database
    ) throws -> String {
        try proposal.insert(db)
        for item in items {
            var i = item
            i.proposalID = proposal.id
            try i.insert(db)
        }
        return proposal.id
    }

    /// Proposte con lo stato indicato, dalla più recente.
    public static func fetch(status: String, in db: Database) throws -> [DBProposal] {
        try DBProposal
            .filter(Column("status") == status)
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }

    public static func fetch(id: String, in db: Database) throws -> DBProposal? {
        try DBProposal.fetchOne(db, key: id)
    }

    public static func items(proposalID: String, in db: Database) throws -> [DBProposalItem] {
        try DBProposalItem
            .filter(Column("proposalID") == proposalID)
            .order(Column("id").asc)
            .fetchAll(db)
    }

    public static func countPending(in db: Database) throws -> Int {
        try DBProposal.filter(Column("status") == "pending").fetchCount(db)
    }

    /// Segna la proposta come applicata, collegandola al batch di scrittura.
    public static func markApplied(id: String, batchID: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE mcp_proposal SET status='applied', batchID=?, decidedAt=? WHERE id=?",
            arguments: [batchID, Date(), id]
        )
    }

    public static func markRejected(id: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE mcp_proposal SET status='rejected', decidedAt=? WHERE id=?",
            arguments: [Date(), id]
        )
    }
}
