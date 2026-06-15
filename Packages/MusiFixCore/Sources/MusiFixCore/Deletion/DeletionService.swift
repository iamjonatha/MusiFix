import Foundation
import Persistence
import GRDB
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "DeletionService")

/// Scope di una eliminazione.
public enum DeletionScope: String, Sendable, CaseIterable {
    case fromMusicOnly     = "music_only"
    case fromMusicAndTrash = "music_and_trash"
}

/// Risultato di un'operazione di eliminazione.
public struct DeletionResult: Sendable {
    public let batchID: String
    public let succeeded: [String]              // persistentID rimossi
    public let failed: [(String, String)]       // (persistentID, messaggio errore)
    public let trashedPaths: [String]           // path fisici spostati nel Cestino

    public var allSucceeded: Bool { failed.isEmpty && !succeeded.isEmpty }
}

/// Actor che gestisce l'eliminazione di brani dalla libreria Music e (opzionale) dal file system.
/// Registra ogni operazione nella tabella `deletion_log` che persiste anche dopo la rimozione
/// del brano dall'indice.
public actor DeletionService {

    private let db: AppDatabase
    private let bridge: any AppleMusicBridge

    public static let doubleConfirmThreshold = 10

    public init(db: AppDatabase, bridge: any AppleMusicBridge) {
        self.db = db
        self.bridge = bridge
    }

    // ── Eliminazione batch ────────────────────────────────────────────────────

    public func delete(
        tracks: [DBTrack],
        scope: DeletionScope
    ) async throws -> DeletionResult {
        let batchID = UUID().uuidString
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        var trashedPaths: [String] = []

        for track in tracks {
            do {
                // 1. Sposta file nel Cestino prima di rimuovere da Music
                //    (se Music ha "Mantieni organizzata" ON potrebbe spostare il file)
                if scope == .fromMusicAndTrash, let path = track.locationPath {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        trashedPaths.append(path)
                        log.info("File spostato nel Cestino: \(path)")
                    }
                }

                // 2. Rimuovi da Music
                try await bridge.deleteTrack(persistentID: track.persistentID)

                // 3. Rimuovi dall'indice SQLite
                try db.write { db in
                    try db.execute(
                        sql: "DELETE FROM track WHERE persistentID = ?",
                        arguments: [track.persistentID]
                    )
                }

                // 4. Registra in deletion_log
                let entry = DBDeletionLog(
                    persistentID: track.persistentID,
                    name: track.name,
                    artist: track.artist,
                    album: track.album,
                    locationPath: track.locationPath,
                    scope: scope.rawValue,
                    deletedAt: Date(),
                    status: "done",
                    batchID: batchID
                )
                try db.write { db in try entry.insert(db) }

                succeeded.append(track.persistentID)
                log.info("Eliminato [\(track.persistentID)] \(track.name) — scope: \(scope.rawValue)")

            } catch {
                failed.append((track.persistentID, error.localizedDescription))
                log.error("Eliminazione fallita [\(track.persistentID)]: \(error)")

                let entry = DBDeletionLog(
                    persistentID: track.persistentID,
                    name: track.name,
                    artist: track.artist,
                    album: track.album,
                    locationPath: track.locationPath,
                    scope: scope.rawValue,
                    deletedAt: Date(),
                    status: "failed",
                    errorMessage: error.localizedDescription,
                    batchID: batchID
                )
                try? db.write { db in try entry.insert(db) }
            }
        }

        return DeletionResult(
            batchID: batchID,
            succeeded: succeeded,
            failed: failed,
            trashedPaths: trashedPaths
        )
    }

    // ── Log eliminazioni ──────────────────────────────────────────────────────

    public func recentDeletions(limit: Int = 50) throws -> [DBDeletionLog] {
        try db.read { db in
            try DBDeletionLog.fetchAll(
                db,
                sql: "SELECT * FROM deletion_log ORDER BY deletedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}
