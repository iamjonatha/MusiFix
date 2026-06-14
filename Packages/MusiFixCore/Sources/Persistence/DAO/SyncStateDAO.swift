import GRDB
import Foundation

public struct SyncStateDAO: Sendable {

    public static func get(key: String, in db: Database) throws -> String? {
        try DBSyncState.fetchOne(db, key: key)?.value
    }

    public static func set(key: String, value: String, in db: Database) throws {
        let row = DBSyncState(key: key, value: value, updatedAt: Date())
        try row.upsert(db)
    }

    public static func lastMusicSyncDate(in db: Database) throws -> Date? {
        guard let s = try get(key: "last_music_sync", in: db) else { return nil }
        return Date(timeIntervalSince1970: Double(s) ?? 0)
    }

    public static func setLastMusicSync(_ date: Date, in db: Database) throws {
        try set(key: "last_music_sync", value: "\(date.timeIntervalSince1970)", in: db)
    }

    public static func lastFSEventsID(in db: Database) throws -> UInt64? {
        guard let s = try get(key: "fsevents_last_event_id", in: db) else { return nil }
        return UInt64(s)
    }

    public static func setLastFSEventsID(_ id: UInt64, in db: Database) throws {
        try set(key: "fsevents_last_event_id", value: "\(id)", in: db)
    }
}
