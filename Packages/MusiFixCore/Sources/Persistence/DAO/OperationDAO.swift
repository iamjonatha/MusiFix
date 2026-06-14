import GRDB
import Foundation

public struct OperationDAO: Sendable {

    public static func insert(_ op: DBOperation, in db: Database) throws -> Int64 {
        var op = op
        try op.insert(db)
        return op.id!
    }

    public static func updateStatus(
        id: Int64,
        status: String,
        error: String? = nil,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE operation_log SET status = ?, errorMessage = ? WHERE id = ?",
            arguments: [status, error, id]
        )
    }

    public static func fetchPending(in db: Database) throws -> [DBOperation] {
        try DBOperation.filter(Column("status") == "pending")
            .order(Column("performedAt").asc)
            .fetchAll(db)
    }

    public static func fetchForTrack(persistentID: String, in db: Database) throws -> [DBOperation] {
        try DBOperation.filter(Column("persistentID") == persistentID)
            .order(Column("performedAt").desc)
            .fetchAll(db)
    }

    public static func fetchBatch(batchID: String, in db: Database) throws -> [DBOperation] {
        try DBOperation.filter(Column("batchID") == batchID)
            .order(Column("performedAt").asc)
            .fetchAll(db)
    }

    /// Ultimi N batch distinti, con la prima operazione per gruppo come rappresentante.
    public static func fetchRecentBatches(limit: Int = 30, in db: Database) throws -> [DBOperation] {
        try DBOperation
            .filter(Column("batchID") != nil)
            .order(Column("performedAt").desc)
            .fetchAll(db)
            .reduce(into: [String: DBOperation]()) { acc, op in
                if let bid = op.batchID, acc[bid] == nil { acc[bid] = op }
            }
            .values
            .sorted { ($0.performedAt) > ($1.performedAt) }
            .prefix(limit)
            .map { $0 }
    }

    public static func markUndone(batchID: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE operation_log SET status = 'undone' WHERE batchID = ? AND status = 'done'",
            arguments: [batchID]
        )
    }

    public static func countDone(batchID: String, in db: Database) throws -> Int {
        try DBOperation
            .filter(Column("batchID") == batchID)
            .filter(Column("status") == "done")
            .fetchCount(db)
    }
}
