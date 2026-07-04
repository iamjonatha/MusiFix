import Foundation
import GRDB
import Persistence
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "NormalizationService")

public enum NormalizationField: String, Sendable, Hashable {
    case genre, artist, albumArtist
}

/// Un cambio proposto: tutti i brani con `originalValue` nel campo `field`
/// verranno aggiornati a `normalizedValue`.
public struct NormalizationPreview: Sendable, Identifiable {
    public var id = UUID()
    public let field: NormalizationField
    public let originalValue: String
    public let normalizedValue: String
    public let trackCount: Int
    public let samplePIDs: [String]         // primi 5 per preview
}

/// Risultato di un'applicazione batch di normalizzazione.
public struct NormalizationResult: Sendable {
    public let updated: Int
    public let failed: Int
    public let errors: [(String, String)]   // (pid, messaggio)
}

/// Frammento SQL che esclude i brani "ignorati in MusiFix" (per PID o perché il
/// loro album è ignorato). Da concatenare in coda a una WHERE già presente. (Fase 13)
private let ignoreFilterSQL = """
    AND persistentID NOT IN (SELECT persistentID FROM track_ignore)
    AND (LOWER(COALESCE(NULLIF(albumArtist,''), artist)) || CHAR(31) || LOWER(album))
        NOT IN (SELECT albumKey FROM album_ignore)
    """

/// Regole built-in di normalizzazione genere (sedate nel DB al primo avvio se assente).
private let builtInGenreAliases: [(from: String, to: String)] = [
    ("hip hop", "Hip-Hop"),
    ("hiphop", "Hip-Hop"),
    ("r&b", "R&B"),
    ("rhythm and blues", "R&B"),
    ("rhythm & blues", "R&B"),
    ("rnb", "R&B"),
    ("electronic music", "Electronic"),
    ("electronica", "Electronic"),
    ("rock and roll", "Rock"),
    ("rock & roll", "Rock"),
    ("classic rock", "Rock"),
    ("alternative rock", "Alternative"),
    ("indie rock", "Indie"),
    ("classical music", "Classical"),
    ("folk music", "Folk"),
    ("country music", "Country"),
    ("pop music", "Pop"),
    ("dance music", "Dance"),
    ("reggae music", "Reggae"),
    ("jazz music", "Jazz"),
    ("blues music", "Blues"),
    ("soul music", "Soul"),
    ("punk rock", "Punk"),
    ("hard rock", "Rock"),
    ("heavy metal", "Metal"),
    ("death metal", "Metal"),
    ("black metal", "Metal"),
    ("thrash metal", "Metal"),
]

/// Actor che normalizza generi e artisti usando dizionari editabili + regole built-in.
public actor NormalizationService {

    private let db: AppDatabase
    private let writeService: MetadataWriteService

    // Cache dizionari in-memory (invalidata su ogni modifica)
    private var genreCache: [String: String]? = nil
    private var artistCache: [String: String]? = nil

    public init(db: AppDatabase, writeService: MetadataWriteService) {
        self.db = db
        self.writeService = writeService
    }

    // ── Setup ─────────────────────────────────────────────────────────────────

    /// Popola le aliases built-in se la tabella è vuota.
    public func seedBuiltInAliasesIfNeeded() throws {
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM genre_alias") ?? 0 }
        guard count == 0 else { return }
        try db.write { db in
            for alias in builtInGenreAliases {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO genre_alias (\"from\", \"to\") VALUES (?, ?)",
                    arguments: [alias.from, alias.to]
                )
            }
        }
        log.info("Seeded \(builtInGenreAliases.count) genre aliases")
        genreCache = nil
    }

    // ── Dizionari CRUD ────────────────────────────────────────────────────────

    public func genreAliases() throws -> [(from: String, to: String)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT \"from\", \"to\" FROM genre_alias ORDER BY \"from\"")
                .map { row -> (from: String, to: String) in (row["from"], row["to"]) }
        }
    }

    public func artistAliases() throws -> [(from: String, to: String)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT \"from\", \"to\" FROM artist_alias ORDER BY \"from\"")
                .map { row -> (from: String, to: String) in (row["from"], row["to"]) }
        }
    }

    public func addGenreAlias(from: String, to: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO genre_alias (\"from\", \"to\") VALUES (?, ?)",
                           arguments: [from.lowercased(), to])
        }
        genreCache = nil
    }

    public func removeGenreAlias(from: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM genre_alias WHERE \"from\" = ?", arguments: [from.lowercased()])
        }
        genreCache = nil
    }

    public func addArtistAlias(from: String, to: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO artist_alias (\"from\", \"to\") VALUES (?, ?)",
                           arguments: [from.lowercased(), to])
        }
        artistCache = nil
    }

    public func removeArtistAlias(from: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM artist_alias WHERE \"from\" = ?", arguments: [from.lowercased()])
        }
        artistCache = nil
    }

    // ── Normalizzazione ───────────────────────────────────────────────────────

    /// Normalizza un genere applicando regole + dizionario.
    public func normalizeGenre(_ genre: String) throws -> String {
        let aliases = try loadGenreAliases()
        return applyRules(to: genre, aliases: aliases)
    }

    /// Normalizza un artista applicando regole + dizionario.
    public func normalizeArtist(_ artist: String) throws -> String {
        let aliases = try loadArtistAliases()
        return applyArtistRules(to: artist, aliases: aliases)
    }

    // ── Preview impatto ───────────────────────────────────────────────────────

    /// Calcola l'anteprima dell'impatto di normalizzazione generi.
    public func previewGenreNormalization() async throws -> [NormalizationPreview] {
        let aliases = try loadGenreAliases()

        // Raggruppa tutti i generi distinti con i loro track
        let pairs: [(genre: String, pid: String)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT genre, persistentID
                FROM track WHERE genre != '' AND TRIM(genre) != ''
                \(ignoreFilterSQL)
                ORDER BY genre
                """)
            .map { row -> (String, String) in (row["genre"], row["persistentID"]) }
        }

        var byGenre: [String: [String]] = [:]
        for (g, pid) in pairs { byGenre[g, default: []].append(pid) }

        var previews: [NormalizationPreview] = []
        for (genre, pids) in byGenre {
            let normalized = applyRules(to: genre, aliases: aliases)
            guard normalized != genre, !normalized.isEmpty else { continue }
            previews.append(NormalizationPreview(
                field: .genre,
                originalValue: genre,
                normalizedValue: normalized,
                trackCount: pids.count,
                samplePIDs: Array(pids.prefix(5))
            ))
        }
        return previews.sorted { $0.trackCount > $1.trackCount }
    }

    /// Calcola l'anteprima dell'impatto di normalizzazione artisti.
    public func previewArtistNormalization() async throws -> [NormalizationPreview] {
        let aliases = try loadArtistAliases()

        let pairs: [(artist: String, pid: String)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT artist, persistentID
                FROM track WHERE artist != '' AND TRIM(artist) != ''
                \(ignoreFilterSQL)
                ORDER BY artist
                """)
            .map { row -> (String, String) in (row["artist"], row["persistentID"]) }
        }

        var byArtist: [String: [String]] = [:]
        for (a, pid) in pairs { byArtist[a, default: []].append(pid) }

        var previews: [NormalizationPreview] = []
        for (artist, pids) in byArtist {
            let normalized = applyArtistRules(to: artist, aliases: aliases)
            guard normalized != artist, !normalized.isEmpty else { continue }
            previews.append(NormalizationPreview(
                field: .artist,
                originalValue: artist,
                normalizedValue: normalized,
                trackCount: pids.count,
                samplePIDs: Array(pids.prefix(5))
            ))
        }
        return previews.sorted { $0.trackCount > $1.trackCount }
    }

    /// Applica le normalizzazioni selezionate scrivendo su Music tramite writeService.
    public func applyNormalization(
        _ previews: [NormalizationPreview],
        excluding excludedOriginals: Set<String> = []
    ) async throws -> NormalizationResult {
        var updated = 0; var failed = 0; var errors: [(String, String)] = []

        for preview in previews where !excludedOriginals.contains(preview.originalValue) {
            // Recupera tutti i PID con questo valore originale
            let pids: [String] = try db.read { db in
                let col = preview.field == .genre ? "genre" : "artist"
                return try String.fetchAll(db, sql: """
                    SELECT persistentID FROM track WHERE \(col) = ?
                    \(ignoreFilterSQL)
                    """,
                    arguments: [preview.originalValue])
            }

            let items: [(TrackMetadataUpdate, String)] = pids.map { pid in
                var u = TrackMetadataUpdate()
                switch preview.field {
                case .genre:       u.genre = preview.normalizedValue
                case .artist:      u.artist = preview.normalizedValue
                case .albumArtist: u.albumArtist = preview.normalizedValue
                }
                return (u, pid)
            }

            let result = try await writeService.writeBatch(items)
            updated += result.succeeded.count
            failed += result.failed.count
            errors.append(contentsOf: result.failed)
        }

        return NormalizationResult(updated: updated, failed: failed, errors: errors)
    }

    // ── Helpers privati ───────────────────────────────────────────────────────

    private func loadGenreAliases() throws -> [String: String] {
        if let cached = genreCache { return cached }
        let aliases: [String: String] = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT \"from\", \"to\" FROM genre_alias")
                .reduce(into: [String: String]()) { dict, row in dict[row["from"]] = row["to"] }
        }
        genreCache = aliases
        return aliases
    }

    private func loadArtistAliases() throws -> [String: String] {
        if let cached = artistCache { return cached }
        let aliases: [String: String] = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT \"from\", \"to\" FROM artist_alias")
                .reduce(into: [String: String]()) { dict, row in dict[row["from"]] = row["to"] }
        }
        artistCache = aliases
        return aliases
    }

    /// Applica normalizzazione genere: alias lookup → casing → trim.
    private func applyRules(to genre: String, aliases: [String: String]) -> String {
        let key = genre.lowercased().trimmingCharacters(in: .whitespaces)
        if let canonical = aliases[key] { return canonical }
        // Normalizza spazi multipli
        let trimmed = genre.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return trimmed
    }

    /// Applica normalizzazione artista: alias lookup + feat. normalization.
    private func applyArtistRules(to artist: String, aliases: [String: String]) -> String {
        let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
        if let canonical = aliases[key] { return canonical }

        var result = artist.trimmingCharacters(in: .whitespaces)

        // Normalizza "feat." variations
        let featPatterns = ["featuring", "Featuring", "feat ", "Feat ", "ft.", "Ft."]
        for pattern in featPatterns {
            result = result.replacingOccurrences(of: pattern, with: "feat.")
        }

        // Collassa spazi multipli
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return result
    }
}
