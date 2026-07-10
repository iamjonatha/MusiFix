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

/// Una variante di un nome artista scritta in un modo specifico, con il numero di brani.
public struct ArtistVariant: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let trackCount: Int
}

/// Un gruppo di nomi artista giudicati simili tra loro (scritti in modo diverso).
/// L'utente sceglie il `suggestedName` (o lo modifica) come nome normalizzato del gruppo.
public struct ArtistSimilarityGroup: Sendable, Identifiable {
    public var id = UUID()
    public let variants: [ArtistVariant]   // 2+ nomi simili, ordinati per frequenza discendente
    public let suggestedName: String       // proposta iniziale (variante più frequente)
    public var totalTracks: Int { variants.reduce(0) { $0 + $1.trackCount } }
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

    // ── Similitudine artisti (fuzzy) ──────────────────────────────────────────

    /// Individua gruppi di nomi artista scritti in modo diverso ma probabilmente
    /// riferiti allo stesso artista (case/diacritici/punteggiatura diversi, refusi).
    /// Non modifica nulla: restituisce i gruppi affinché l'utente scelga il nome
    /// normalizzato per ciascuno.
    ///
    /// - Parameter threshold: soglia di similitudine [0,1] per accostare due nomi
    ///   che non coincidono già dopo la normalizzazione della chiave (default 0.82).
    public func findSimilarArtists(threshold: Double = 0.82) async throws -> [ArtistSimilarityGroup] {
        // Nomi artista distinti col conteggio brani (escludendo gli ignorati).
        let rows: [(name: String, count: Int)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT artist AS name, COUNT(*) AS cnt
                FROM track WHERE artist != '' AND TRIM(artist) != ''
                \(ignoreFilterSQL)
                GROUP BY artist
                """)
            .map { row -> (String, Int) in (row["name"], row["cnt"]) }
        }
        guard rows.count > 1 else { return [] }

        let keys = rows.map { artistKey($0.name) }

        // Union-find per raggruppare gli indici delle varianti equivalenti.
        var parent = Array(0..<rows.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // 1) Fusione esatta sulla chiave normalizzata (case/diacritici/punteggiatura).
        var firstByKey: [String: Int] = [:]
        for (i, k) in keys.enumerated() where !k.isEmpty {
            if let j = firstByKey[k] { union(i, j) } else { firstByKey[k] = i }
        }

        // 2) Fusione fuzzy (refusi) limitata a blocchi per iniziale, per contenere il costo.
        var buckets: [Character: [Int]] = [:]
        for (i, k) in keys.enumerated() where !k.isEmpty {
            buckets[k.first!, default: []].append(i)
        }
        for (_, idxs) in buckets {
            for a in 0..<idxs.count {
                for b in (a + 1)..<idxs.count {
                    let i = idxs[a], j = idxs[b]
                    if find(i) == find(j) { continue }
                    let ki = keys[i], kj = keys[j]
                    if abs(ki.count - kj.count) > 3 { continue }
                    if similarity(ki, kj) >= threshold { union(i, j) }
                }
            }
        }

        // Raccogli i cluster con più di una variante.
        var clusters: [Int: [Int]] = [:]
        for i in 0..<rows.count where !keys[i].isEmpty { clusters[find(i), default: []].append(i) }

        var result: [ArtistSimilarityGroup] = []
        for (_, members) in clusters where members.count > 1 {
            let variants = members
                .map { ArtistVariant(name: rows[$0].name, trackCount: rows[$0].count) }
                .sorted { $0.trackCount > $1.trackCount }
            result.append(ArtistSimilarityGroup(variants: variants, suggestedName: variants[0].name))
        }
        return result.sorted { $0.totalTracks > $1.totalTracks }
    }

    /// Unifica le varianti indicate sotto `normalizedName`: registra gli alias (così
    /// le future importazioni normalizzano da sole) e riscrive i brani su Music.
    @discardableResult
    public func unifyArtists(
        variants: [String],
        to normalizedName: String
    ) async throws -> NormalizationResult {
        let target = normalizedName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            return NormalizationResult(updated: 0, failed: 0, errors: [])
        }

        var updated = 0; var failed = 0; var errors: [(String, String)] = []

        for variant in variants where variant != target {
            // Registra l'alias per le normalizzazioni future.
            try db.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO artist_alias (\"from\", \"to\") VALUES (?, ?)",
                    arguments: [variant.lowercased(), target]
                )
            }

            // Riscrivi i brani con questo valore originale.
            let pids: [String] = try db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT persistentID FROM track WHERE artist = ?
                    \(ignoreFilterSQL)
                    """,
                    arguments: [variant])
            }
            let items: [(TrackMetadataUpdate, String)] = pids.map { pid in
                var u = TrackMetadataUpdate(); u.artist = target
                return (u, pid)
            }
            if !items.isEmpty {
                let result = try await writeService.writeBatch(items)
                updated += result.succeeded.count
                failed += result.failed.count
                errors.append(contentsOf: result.failed)
            }
        }

        artistCache = nil
        return NormalizationResult(updated: updated, failed: failed, errors: errors)
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

    /// Chiave di confronto per un nome artista: minuscolo, senza diacritici,
    /// punteggiatura ridotta a spazi, spazi collassati. Uguaglia varianti tipo
    /// "Beyoncé"/"Beyonce", "Jay-Z"/"Jay Z", "The Beatles"/"the beatles".
    private func artistKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Similitudine [0,1] tra due stringhe = 1 − distanzaLevenshtein / lunghezzaMax.
    private func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let dist = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    /// Distanza di Levenshtein con due sole righe di lavoro.
    private func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
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
