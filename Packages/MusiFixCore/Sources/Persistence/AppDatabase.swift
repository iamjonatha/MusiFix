import GRDB
import Foundation
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "Database")

/// Punto di accesso al database SQLite.
/// `DatabasePool` consente letture concorrenti + una sola scrittura serializzata.
public final class AppDatabase: Sendable {
    public let pool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.label = "it.musifixapp.db"
        config.maximumReaderCount = 4
        // WAL mode per letture non-bloccanti durante le scritture
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: path, configuration: config)
        try migrate()
        log.info("Database aperto: \(path)")
    }

    /// Accesso in-memory per i test.
    public static func makeInMemory() throws -> AppDatabase {
        let db = AppDatabase.__unsafeInMemory()
        return db
    }

    private static func __unsafeInMemory() -> AppDatabase {
        // swiftlint:disable force_try
        return try! AppDatabase(path: ":memory:")
        // swiftlint:enable force_try
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif
        Migrations.register(in: &migrator)
        try migrator.migrate(pool)
    }
}

// ── Shortcut per letture/scritture ──────────────────────────────────────────

extension AppDatabase {
    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try pool.write(block)
    }
}
