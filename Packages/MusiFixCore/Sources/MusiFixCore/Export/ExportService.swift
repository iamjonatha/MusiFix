import Foundation
import Persistence
import GRDB
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "ExportService")

/// Actor di sola lettura che genera report Markdown della libreria.
/// Quattro report indipendenti: brani caricati, brani solo cloud,
/// album incompleti, album con almeno un brano caricato (esclusi i singoli).
public actor ExportService {

    private let db: AppDatabase
    private let albumService: AlbumService

    public init(db: AppDatabase, albumService: AlbumService) {
        self.db = db
        self.albumService = albumService
    }

    // ── Brani ────────────────────────────────────────────────────────────────

    /// Brani con stato iCloud «Caricato» (uploaded): file caricati su iCloud
    /// Music Library, non abbinati al catalogo Apple.
    public func uploadedTracksMarkdown() throws -> String {
        let tracks = try db.read { db in
            try TrackDAO.fetchAllFiltered(filter: .cloudStatus(CloudStatus.uploaded.code), in: db)
        }
        return MarkdownExport.trackTable(
            title: "Brani caricati (uploaded)",
            subtitle: "Brani caricati su iCloud Music Library, non abbinati al catalogo Apple.",
            tracks: tracks
        )
    }

    /// Brani solo cloud: nessun file locale, l'audio risiede unicamente su iCloud.
    public func cloudOnlyTracksMarkdown() throws -> String {
        let tracks = try db.read { db in
            try TrackDAO.fetchAllFiltered(filter: .cloudOnly, in: db)
        }
        return MarkdownExport.trackTable(
            title: "Brani solo cloud",
            subtitle: "Brani senza file locale: l'audio risiede unicamente su iCloud.",
            tracks: tracks
        )
    }

    // ── Album ────────────────────────────────────────────────────────────────

    /// Album incompleti (brani presenti < trackCount tag), esclusi i singoli,
    /// ordinati per numero di brani mancanti decrescente.
    public func incompleteAlbumsMarkdown() async throws -> String {
        let albums = try await albumService.incompleteAlbums()
        return MarkdownExport.incompleteAlbumsTable(albums)
    }

    /// Album (esclusi i singoli) con almeno un brano in stato «Caricato».
    public func albumsWithUploadedMarkdown() async throws -> String {
        let albums = try await albumService.albumGroups().filter {
            $0.cloudStatusCounts[CloudStatus.uploaded.code, default: 0] > 0
        }
        return MarkdownExport.albumsWithUploadedTable(albums)
    }
}

// ── Generazione Markdown (pura, senza DB) ───────────────────────────────────────

/// Costruttori Markdown puri: input già materializzato, nessun accesso al DB.
enum MarkdownExport {

    static func trackTable(title: String, subtitle: String, tracks: [DBTrack]) -> String {
        var out = "# \(title)\n\n"
        out += "_\(subtitle)_\n\n"
        out += "_Esportato il \(today()) · \(tracks.count) brani_\n\n"
        guard !tracks.isEmpty else { return out + "Nessun brano in questa categoria.\n" }

        out += "| # | Artista | Titolo | Album | Anno | Formato | Stato iCloud | File locale |\n"
        out += "|---:|---|---|---|---:|---|---|:---:|\n"
        for (i, t) in tracks.enumerated() {
            let anno = t.year > 0 ? "\(t.year)" : ""
            let stato = CloudStatus(code: t.cloudStatus).label
            let locale = t.locationPath != nil ? "sì" : "no"
            out += "| \(i + 1) | \(cell(t.artist)) | \(cell(t.name)) | \(cell(t.album)) "
                 + "| \(anno) | \(cell(t.format)) | \(stato) | \(locale) |\n"
        }
        return out
    }

    static func incompleteAlbumsTable(_ albums: [AlbumGroup]) -> String {
        var out = "# Album incompleti\n\n"
        out += "_Album con meno brani del totale indicato nei tag (esclusi i singoli). "
             + "Ordinati per brani mancanti decrescenti._\n\n"
        out += "_Esportato il \(today()) · \(albums.count) album_\n\n"
        guard !albums.isEmpty else { return out + "Nessun album incompleto.\n" }

        out += "| # | Artista | Album | Presenti | Totale | Mancanti | Stato cloud |\n"
        out += "|---:|---|---|---:|---:|---:|---|\n"
        for (i, a) in albums.enumerated() {
            let mancanti = max(0, a.tagTrackCount - a.actualCount)
            out += "| \(i + 1) | \(cell(a.albumArtist)) | \(cell(a.album)) "
                 + "| \(a.actualCount) | \(a.tagTrackCount) | \(mancanti) | \(cell(cloudSummary(a))) |\n"
        }
        return out
    }

    static func albumsWithUploadedTable(_ albums: [AlbumGroup]) -> String {
        var out = "# Album con almeno un brano caricato\n\n"
        out += "_Album (esclusi i singoli) che contengono almeno un brano con stato iCloud «Caricato»._\n\n"
        out += "_Esportato il \(today()) · \(albums.count) album_\n\n"
        guard !albums.isEmpty else { return out + "Nessun album con brani caricati.\n" }

        out += "| # | Artista | Album | Caricati | Brani presenti | Completezza | Stato cloud |\n"
        out += "|---:|---|---|---:|---:|---|---|\n"
        for (i, a) in albums.enumerated() {
            let caricati = a.cloudStatusCounts[CloudStatus.uploaded.code, default: 0]
            out += "| \(i + 1) | \(cell(a.albumArtist)) | \(cell(a.album)) "
                 + "| \(caricati) | \(a.actualCount) | \(completenessLabel(a.completeness)) | \(cell(cloudSummary(a))) |\n"
        }
        return out
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Sanitizza una cella di tabella: niente pipe/newline, vuoto → «—».
    private static func cell(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "—" }
        return t.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
    }

    /// Riepilogo stati iCloud, es. "Abbinato 8 · Caricato 2".
    private static func cloudSummary(_ a: AlbumGroup) -> String {
        a.cloudStatusCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { "\(CloudStatus(code: $0.key).label) \($0.value)" }
            .joined(separator: " · ")
    }

    private static func completenessLabel(_ c: AlbumCompleteness) -> String {
        switch c {
        case .complete:   return "Completo"
        case .incomplete: return "Incompleto"
        case .excess:     return "Eccesso"
        case .unknown:    return "Senza tag"
        case .multiDisc:  return "Multi-disco"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func today() -> String { dayFormatter.string(from: Date()) }
}
