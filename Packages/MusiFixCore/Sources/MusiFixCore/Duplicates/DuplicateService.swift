import Foundation
import GRDB
import Persistence
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "DuplicateService")

/// Un gruppo di brani potenzialmente duplicati.
public struct DuplicateGroup: Sendable, Identifiable {
    public var id = UUID()
    public let tracks: [DBTrack]
    public let score: Double
    public let hasFingerprint: Bool
    public let suggestedKeeper: Int

    public init(tracks: [DBTrack], score: Double, hasFingerprint: Bool) {
        self.tracks = tracks
        self.score = score
        self.hasFingerprint = hasFingerprint
        self.suggestedKeeper = DuplicateGroup.selectKeeper(tracks)
    }

    private static func selectKeeper(_ tracks: [DBTrack]) -> Int {
        let lossless: Set<String> = ["m4a", "aiff", "aif", "wav", "flac", "alac"]
        var best = 0
        for (i, t) in tracks.enumerated() {
            let bl = lossless.contains(t.format.lowercased())
            let al = lossless.contains(tracks[best].format.lowercased())
            if bl && !al { best = i; continue }
            if !bl && al { continue }
            if t.bitRate > tracks[best].bitRate { best = i }
        }
        return best
    }
}

/// Actor che trova duplicati per metadati (F4.3) e fingerprint audio (F4.4).
public actor DuplicateService {

    private let db: AppDatabase
    private let fingerprinter = AudioFingerprinter()

    public init(db: AppDatabase) { self.db = db }

    // ── Duplicati per metadati ────────────────────────────────────────────────

    public func findMetadataDuplicates(
        titleThreshold: Double = 0.85,
        durationTolerance: Double = 5.0
    ) async throws -> [DuplicateGroup] {

        // Mappa dentro db.read per evitare Row cross-actor (non Sendable)
        struct TrackRow { let pid, artist, name: String; let duration: Double }
        let rows: [TrackRow] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, artistNormalized, name, duration
                FROM track ORDER BY artistNormalized, name
                """)
            .map { TrackRow(pid: $0["persistentID"], artist: $0["artistNormalized"],
                            name: ($0["name"] as String).lowercased(), duration: $0["duration"]) }
        }

        var blocks: [String: [TrackRow]] = [:]
        for r in rows {
            let key = "\(r.artist.prefix(4))|\(r.name.prefix(3))"
            blocks[key, default: []].append(r)
        }

        let ignored = try loadIgnoredPairs()
        var groups: [DuplicateGroup] = []
        var visited: Set<String> = []

        for bucket in blocks.values where bucket.count >= 2 {
            for i in 0..<bucket.count {
                for j in (i+1)..<bucket.count {
                    let a = bucket[i], b = bucket[j]
                    let pairKey = pairID(a.pid, b.pid)
                    guard !visited.contains(pairKey), !ignored.contains(pairKey) else { continue }
                    guard abs(a.duration - b.duration) <= durationTolerance else { continue }
                    let score = FuzzyMatch.similarity(a.name, b.name)
                    guard score >= titleThreshold else { continue }
                    visited.insert(pairKey)

                    let tracks = try db.read { db in
                        try DBTrack.filter(keys: [a.pid, b.pid]).fetchAll(db)
                    }
                    guard tracks.count == 2 else { continue }
                    groups.append(DuplicateGroup(tracks: tracks, score: score, hasFingerprint: false))
                }
            }
        }
        return groups.sorted { $0.score > $1.score }
    }

    // ── Fingerprint audio ─────────────────────────────────────────────────────

    public func computeFingerprints(
        onProgress: @Sendable (Int, Int) -> Void
    ) async throws {
        // Mappa Path+PID dentro db.read
        let targets: [(pid: String, path: String)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, locationPath FROM track
                WHERE isCloudOnly = 0 AND locationPath IS NOT NULL AND audioFingerprint IS NULL
                """)
            .compactMap { row -> (String, String)? in
                guard let path: String = row["locationPath"] else { return nil }
                return (row["persistentID"], path)
            }
        }

        let total = targets.count
        for (idx, target) in targets.enumerated() {
            let url = URL(fileURLWithPath: target.path)
            do {
                let fp = try await fingerprinter.fingerprint(for: url)
                let data = fp.withUnsafeBytes { Data($0) }
                try db.write { db in
                    try db.execute(
                        sql: "UPDATE track SET audioFingerprint = ? WHERE persistentID = ?",
                        arguments: [data, target.pid]
                    )
                }
            } catch {
                log.warning("Fingerprint fallito per \(target.pid): \(error)")
            }
            onProgress(idx + 1, total)
        }
        log.info("Fingerprint calcolati: \(total)")
    }

    public func findFingerprintDuplicates(threshold: Double = 0.88) async throws -> [DuplicateGroup] {
        // Decodifica i fingerprint dentro db.read
        struct FPRow { let pid: String; let fp: [UInt32] }
        let fpRows: [FPRow] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT persistentID, audioFingerprint FROM track
                WHERE audioFingerprint IS NOT NULL ORDER BY persistentID
                """)
            .compactMap { row -> FPRow? in
                guard let data: Data = row["audioFingerprint"] else { return nil }
                let fp = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
                return FPRow(pid: row["persistentID"], fp: fp)
            }
        }

        let ignored = try loadIgnoredPairs()
        var groups: [DuplicateGroup] = []
        var visited: Set<String> = []

        for i in 0..<fpRows.count {
            for j in (i+1)..<fpRows.count {
                let pairKey = pairID(fpRows[i].pid, fpRows[j].pid)
                guard !visited.contains(pairKey), !ignored.contains(pairKey) else { continue }
                let score = AudioFingerprinter.similarity(fpRows[i].fp, fpRows[j].fp)
                guard score >= threshold else { continue }
                visited.insert(pairKey)
                let tracks = try db.read { db in
                    try DBTrack.filter(keys: [fpRows[i].pid, fpRows[j].pid]).fetchAll(db)
                }
                guard tracks.count == 2 else { continue }
                groups.append(DuplicateGroup(tracks: tracks, score: score, hasFingerprint: true))
            }
        }
        return groups.sorted { $0.score > $1.score }
    }

    // ── Gestione "non duplicati" ──────────────────────────────────────────────

    public func markNotDuplicate(pid1: String, pid2: String) throws {
        let (a, b) = sorted(pid1, pid2)
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO duplicate_ignore (pid1, pid2, ignoredAt) VALUES (?, ?, ?)",
                arguments: [a, b, Date()]
            )
        }
    }

    public func unmarkNotDuplicate(pid1: String, pid2: String) throws {
        let (a, b) = sorted(pid1, pid2)
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM duplicate_ignore WHERE pid1 = ? AND pid2 = ?",
                arguments: [a, b]
            )
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func loadIgnoredPairs() throws -> Set<String> {
        let pairs: [(String, String)] = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT pid1, pid2 FROM duplicate_ignore")
                .map { ($0["pid1"], $0["pid2"]) }
        }
        return Set(pairs.map { pairID($0.0, $0.1) })
    }

    private func sorted(_ a: String, _ b: String) -> (String, String) { a < b ? (a, b) : (b, a) }
    private func pairID(_ a: String, _ b: String) -> String {
        let (x, y) = sorted(a, b); return "\(x):\(y)"
    }
}
