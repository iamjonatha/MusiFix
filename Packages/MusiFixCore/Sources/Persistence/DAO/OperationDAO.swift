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
}
