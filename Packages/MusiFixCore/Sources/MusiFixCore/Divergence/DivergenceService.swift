import Foundation
import Persistence
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "DivergenceService")

public struct TrackDivergence: Sendable, Identifiable {
    public var id: String { persistentID }
    public let persistentID: String
    public let displayName: String
    public let fields: [DivergentField]
}

public struct DivergentField: Sendable, Identifiable {
    public var id: String { fieldName }
    public let fieldName: String
    public let displayName: String
    public let dbValue: String
    public let musicValue: String
}

/// Confronta i valori del DB locale con quelli live di Music.app
/// e risolve le divergenze in entrambe le direzioni.
public actor DivergenceService {

    private let db: AppDatabase
    private let bridge: any AppleMusicBridge
    private let writeService: MetadataWriteService

    public init(db: AppDatabase, bridge: any AppleMusicBridge, writeService: MetadataWriteService) {
        self.db = db
        self.bridge = bridge
        self.writeService = writeService
    }

    /// Recupera i valori live da Music.app per i PID forniti e restituisce solo i brani con campi divergenti.
    public func detect(pids: [String]) async throws -> [TrackDivergence] {
        var result: [TrackDivergence] = []
        for pid in pids {
            guard let dbTrack = try db.read({ db in try TrackDAO.fetch(persistentID: pid, in: db) }) else { continue }
            let musicTrack = try await bridge.trackMetadata(persistentID: pid)
            let fields = divergentFields(db: dbTrack, music: musicTrack)
            guard !fields.isEmpty else { continue }
            let artist = dbTrack.artist.isEmpty ? musicTrack.artist : dbTrack.artist
            let name   = dbTrack.name.isEmpty   ? musicTrack.name   : dbTrack.name
            let display = artist.isEmpty ? name : "\(artist) — \(name)"
            result.append(TrackDivergence(persistentID: pid, displayName: display, fields: fields))
        }
        log.info("Rilevate \(result.count) divergenze su \(pids.count) brani")
        return result
    }

    /// DB vince: invia i valori del DB verso Music.app per i campi divergenti.
    public func applyDB(_ divergence: TrackDivergence) async throws {
        var update = TrackMetadataUpdate()
        for f in divergence.fields {
            applyToUpdate(field: f.fieldName, value: f.dbValue, into: &update)
        }
        _ = try await writeService.write(update, for: divergence.persistentID)
        log.info("applyDB \(divergence.persistentID): \(divergence.fields.map(\.fieldName).joined(separator: ", "))")
    }

    /// Music vince: aggiorna il DB con i valori correnti di Music.app per i campi divergenti.
    public func applyMusic(_ divergence: TrackDivergence) async throws {
        let musicTrack = try await bridge.trackMetadata(persistentID: divergence.persistentID)
        try db.write { db in
            guard var track = try TrackDAO.fetch(persistentID: divergence.persistentID, in: db) else { return }
            for f in divergence.fields {
                applyMusicField(f.fieldName, from: musicTrack, to: &track)
            }
            track.indexedAt = Date()
            try TrackDAO.upsert(track, in: db)
        }
        log.info("applyMusic \(divergence.persistentID): \(divergence.fields.map(\.fieldName).joined(separator: ", "))")
    }

    // MARK: - Helpers

    private func divergentFields(db: DBTrack, music: Track) -> [DivergentField] {
        var out: [DivergentField] = []

        func str(_ fn: String, _ dn: String, _ dv: String, _ mv: String) {
            if dv != mv { out.append(.init(fieldName: fn, displayName: dn, dbValue: dv, musicValue: mv)) }
        }
        func int(_ fn: String, _ dn: String, _ dv: Int, _ mv: Int) {
            str(fn, dn, dv > 0 ? "\(dv)" : "", mv > 0 ? "\(mv)" : "")
        }

        str("name",        "Titolo",         db.name,        music.name)
        str("artist",      "Artista",         db.artist,      music.artist)
        str("albumArtist", "Artista album",   db.albumArtist, music.albumArtist)
        str("album",       "Album",           db.album,       music.album)
        str("genre",       "Genere",          db.genre,       music.genre)
        str("comment",     "Commento",        db.comment,     music.comment)
        str("composer",    "Compositore",     db.composer,    music.composer)
        int("year",        "Anno",            db.year,        music.year)
        int("trackNumber", "Traccia n.",      db.trackNumber, music.trackNumber)
        int("trackCount",  "Totale tracce",   db.trackCount,  music.trackCount)
        int("discNumber",  "Disco n.",        db.discNumber,  music.discNumber)
        int("discCount",   "Totale dischi",   db.discCount,   music.discCount)

        return out
    }

    private func applyToUpdate(field: String, value: String, into update: inout TrackMetadataUpdate) {
        switch field {
        case "name":        update.name        = value
        case "artist":      update.artist      = value
        case "albumArtist": update.albumArtist = value
        case "album":       update.album       = value
        case "genre":       update.genre       = value
        case "comment":     update.comment     = value
        case "composer":    update.composer    = value
        case "year":        update.year        = Int(value) ?? 0
        case "trackNumber": update.trackNumber = Int(value) ?? 0
        case "trackCount":  update.trackCount  = Int(value) ?? 0
        case "discNumber":  update.discNumber  = Int(value) ?? 0
        case "discCount":   update.discCount   = Int(value) ?? 0
        default: break
        }
    }

    nonisolated private func applyMusicField(_ field: String, from music: Track, to track: inout DBTrack) {
        switch field {
        case "name":        track.name        = music.name
        case "artist":      track.artist      = music.artist;      track.artistNormalized = music.artist.lowercased()
        case "albumArtist": track.albumArtist = music.albumArtist
        case "album":       track.album       = music.album;       track.albumNormalized  = music.album.lowercased()
        case "genre":       track.genre       = music.genre;       track.genreNormalized  = music.genre.lowercased()
        case "comment":     track.comment     = music.comment
        case "composer":    track.composer    = music.composer
        case "year":        track.year        = music.year
        case "trackNumber": track.trackNumber = music.trackNumber
        case "trackCount":  track.trackCount  = music.trackCount
        case "discNumber":  track.discNumber  = music.discNumber
        case "discCount":   track.discCount   = music.discCount
        default: break
        }
    }
}
