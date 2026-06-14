import Foundation
import Persistence
import GRDB
import OSLog
import ImageIO
import CoreGraphics

private let log = Logger(subsystem: "it.musifixapp", category: "MetadataWriteService")

/// Risultato di una scrittura (singola o batch).
public struct WriteResult: Sendable {
    public let batchID: String
    public let succeeded: [String]      // persistentID riusciti
    public let failed: [(String, String)] // (persistentID, messaggio errore)

    public var allSucceeded: Bool { failed.isEmpty && !succeeded.isEmpty }
}

/// Actor che serializza le scritture verso Music.app, logga le operazioni
/// e supporta undo per batchID.
public actor MetadataWriteService {

    private let db: AppDatabase
    private let bridge: any AppleMusicBridge

    public init(db: AppDatabase, bridge: any AppleMusicBridge) {
        self.db = db
        self.bridge = bridge
    }

    // ── Scrittura singola ─────────────────────────────────────────────────────

    public func write(_ update: TrackMetadataUpdate, for pid: String) async throws -> WriteResult {
        try await writeBatch([(update, pid)])
    }

    // ── Scrittura batch ───────────────────────────────────────────────────────

    public func writeBatch(_ items: [(TrackMetadataUpdate, String)]) async throws -> WriteResult {
        let batchID = UUID().uuidString
        var succeeded: [String] = []
        var failed: [(String, String)] = []

        for (update, pid) in items {
            do {
                // 1. Snapshot "prima" dal DB locale
                let snapshot = try db.read { db in try TrackDAO.fetch(persistentID: pid, in: db) }

                // 2. Registra operazioni pending
                let opIDs: [Int64] = try db.write { db in
                    try makeOperations(update: update, before: snapshot, pid: pid, batchID: batchID)
                        .map { try OperationDAO.insert($0, in: db) }
                }

                // 3. Scrivi su Music via bridge
                try await bridge.updateMetadata(update, persistentID: pid)

                // 4. Aggiorna indice locale (ottimistico — no read-back per velocità batch)
                try db.write { db in
                    if var track = snapshot {
                        applyUpdate(update, to: &track)
                        try TrackDAO.upsert(track, in: db)
                    }
                    for id in opIDs {
                        try OperationDAO.updateStatus(id: id, status: "done", in: db)
                    }
                }

                succeeded.append(pid)
                log.info("Scritto [\(pid)]: \(update.changedFields.joined(separator: ", "))")
            } catch {
                failed.append((pid, error.localizedDescription))
                log.error("Scrittura fallita [\(pid)]: \(error)")
                // Marca le operazioni pending come failed
                try? db.write { db in
                    try db.execute(
                        sql: "UPDATE operation_log SET status='failed', errorMessage=? WHERE batchID=? AND persistentID=? AND status='pending'",
                        arguments: [error.localizedDescription, batchID, pid]
                    )
                }
            }
        }

        return WriteResult(batchID: batchID, succeeded: succeeded, failed: failed)
    }

    // ── Artwork ───────────────────────────────────────────────────────────────

    public func setArtwork(_ imageData: Data, for pid: String) async throws -> WriteResult {
        let batchID = UUID().uuidString
        let data = normalizeImage(imageData) ?? imageData

        let opID: Int64 = try db.write { db in
            let op = DBOperation(persistentID: pid, field: "artwork",
                                 valueBefore: nil, valueAfter: "replaced",
                                 performedAt: Date(), batchID: batchID)
            return try OperationDAO.insert(op, in: db)
        }

        do {
            try await bridge.setArtwork(data, persistentID: pid)
            try db.write { db in
                try OperationDAO.updateStatus(id: opID, status: "done", in: db)
            }
            log.info("Artwork sostituita per [\(pid)] — \(data.count / 1024) KB")
            return WriteResult(batchID: batchID, succeeded: [pid], failed: [])
        } catch {
            try? db.write { db in
                try OperationDAO.updateStatus(id: opID, status: "failed",
                                              error: error.localizedDescription, in: db)
            }
            throw error
        }
    }

    // ── Undo ─────────────────────────────────────────────────────────────────

    /// Ripristina tutti i campi di un batch al valore precedente la scrittura.
    /// Le operazioni artwork non sono annullabili (nessun dato "prima" salvato).
    public func undo(batchID: String) async throws -> WriteResult {
        let ops = try db.read { db in try OperationDAO.fetchBatch(batchID: batchID, in: db) }
        let undoableOps = ops.filter { $0.status == "done" && $0.field != "artwork" }

        guard !undoableOps.isEmpty else {
            return WriteResult(batchID: batchID, succeeded: [], failed: [])
        }

        // Raggruppa per PID e costruisce un update inverso per ciascuno
        var byPID: [String: [DBOperation]] = [:]
        for op in undoableOps { byPID[op.persistentID, default: []].append(op) }

        var succeeded: [String] = []
        var failed: [(String, String)] = []

        for (pid, opList) in byPID {
            do {
                let reverseUpdate = makeReverseUpdate(from: opList)
                try await bridge.updateMetadata(reverseUpdate, persistentID: pid)

                try db.write { db in
                    if var track = try TrackDAO.fetch(persistentID: pid, in: db) {
                        applyUpdate(reverseUpdate, to: &track)
                        try TrackDAO.upsert(track, in: db)
                    }
                    try OperationDAO.markUndone(batchID: batchID, in: db)
                }
                succeeded.append(pid)
            } catch {
                failed.append((pid, error.localizedDescription))
            }
        }

        return WriteResult(batchID: batchID, succeeded: succeeded, failed: failed)
    }

    // ── Helpers privati ───────────────────────────────────────────────────────

    nonisolated private func makeOperations(
        update: TrackMetadataUpdate,
        before: DBTrack?,
        pid: String,
        batchID: String
    ) -> [DBOperation] {
        let now = Date()
        func op(_ field: String, _ bv: String?, _ av: String?) -> DBOperation {
            DBOperation(persistentID: pid, field: field, valueBefore: bv, valueAfter: av,
                        performedAt: now, batchID: batchID)
        }
        var ops: [DBOperation] = []
        if let v = update.name        { ops.append(op("name",        before?.name,                        v)) }
        if let v = update.artist      { ops.append(op("artist",      before?.artist,                      v)) }
        if let v = update.albumArtist { ops.append(op("albumArtist", before?.albumArtist,                 v)) }
        if let v = update.album       { ops.append(op("album",       before?.album,                       v)) }
        if let v = update.year        { ops.append(op("year",        before.map { "\($0.year)" },   "\(v)")) }
        if let v = update.genre       { ops.append(op("genre",       before?.genre,                       v)) }
        if let v = update.comment     { ops.append(op("comment",     before?.comment,                     v)) }
        if let v = update.composer    { ops.append(op("composer",    before?.composer,                    v)) }
        if let v = update.trackNumber { ops.append(op("trackNumber", before.map { "\($0.trackNumber)" }, "\(v)")) }
        if let v = update.trackCount  { ops.append(op("trackCount",  before.map { "\($0.trackCount)" },  "\(v)")) }
        if let v = update.discNumber  { ops.append(op("discNumber",  before.map { "\($0.discNumber)" },  "\(v)")) }
        if let v = update.discCount   { ops.append(op("discCount",   before.map { "\($0.discCount)" },   "\(v)")) }
        return ops
    }

    nonisolated private func applyUpdate(_ update: TrackMetadataUpdate, to track: inout DBTrack) {
        if let v = update.name        { track.name = v }
        if let v = update.artist      { track.artist = v; track.artistNormalized = v.lowercased() }
        if let v = update.albumArtist { track.albumArtist = v }
        if let v = update.album       { track.album = v; track.albumNormalized = v.lowercased() }
        if let v = update.year        { track.year = v }
        if let v = update.genre       { track.genre = v; track.genreNormalized = v.lowercased() }
        if let v = update.comment     { track.comment = v }
        if let v = update.composer    { track.composer = v }
        if let v = update.trackNumber { track.trackNumber = v }
        if let v = update.trackCount  { track.trackCount = v }
        if let v = update.discNumber  { track.discNumber = v }
        if let v = update.discCount   { track.discCount = v }
        track.indexedAt = Date()
    }

    nonisolated private func makeReverseUpdate(from ops: [DBOperation]) -> TrackMetadataUpdate {
        var u = TrackMetadataUpdate()
        for op in ops {
            switch op.field {
            case "name":        u.name        = op.valueBefore ?? ""
            case "artist":      u.artist      = op.valueBefore ?? ""
            case "albumArtist": u.albumArtist = op.valueBefore ?? ""
            case "album":       u.album       = op.valueBefore ?? ""
            case "year":        u.year        = op.valueBefore.flatMap(Int.init) ?? 0
            case "genre":       u.genre       = op.valueBefore ?? ""
            case "comment":     u.comment     = op.valueBefore ?? ""
            case "composer":    u.composer    = op.valueBefore ?? ""
            case "trackNumber": u.trackNumber = op.valueBefore.flatMap(Int.init) ?? 0
            case "trackCount":  u.trackCount  = op.valueBefore.flatMap(Int.init) ?? 0
            case "discNumber":  u.discNumber  = op.valueBefore.flatMap(Int.init) ?? 0
            case "discCount":   u.discCount   = op.valueBefore.flatMap(Int.init) ?? 0
            default: break
            }
        }
        return u
    }

    /// Ridimensiona e converte in JPEG (max 1400px, q=0.85).
    nonisolated private func normalizeImage(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let maxSide = 1400
        let w = img.width; let h = img.height
        let factor = maxSide < max(w, h) ? CGFloat(maxSide) / CGFloat(max(w, h)) : 1.0
        let nw = Int(CGFloat(w) * factor); let nh = Int(CGFloat(h) * factor)
        let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let resized = ctx?.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resized, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// ── TrackMetadataUpdate helpers ───────────────────────────────────────────────

extension TrackMetadataUpdate {
    var changedFields: [String] {
        var f: [String] = []
        if name        != nil { f.append("name") }
        if artist      != nil { f.append("artist") }
        if albumArtist != nil { f.append("albumArtist") }
        if album       != nil { f.append("album") }
        if year        != nil { f.append("year") }
        if genre       != nil { f.append("genre") }
        if comment     != nil { f.append("comment") }
        if composer    != nil { f.append("composer") }
        if trackNumber != nil { f.append("trackNumber") }
        if trackCount  != nil { f.append("trackCount") }
        if discNumber  != nil { f.append("discNumber") }
        if discCount   != nil { f.append("discCount") }
        return f
    }
}
