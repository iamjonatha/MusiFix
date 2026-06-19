import Foundation
import Persistence
import GRDB
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "OrphanScanService")

/// Confidenza con cui un file su disco è considerato orfano.
public enum OrphanConfidence: Sendable, Equatable {
    /// Nessuna traccia in libreria ha questo titolo: orfano ad alta confidenza.
    case confident
    /// Esiste in libreria una traccia con lo stesso titolo (path non risolto):
    /// potrebbe non essere davvero orfano. Da rivedere a mano.
    case possibleMatch(track: String, artist: String)

    public var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }
}

/// Un file audio presente nella cartella media ma non referenziato da alcuna traccia.
public struct OrphanFile: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let fileName: String
    public let artistFolder: String
    public let albumFolder: String
    public let sizeBytes: Int64
    public let modDate: Date?
    public let format: String
    public let confidence: OrphanConfidence

    public init(path: String, fileName: String, artistFolder: String, albumFolder: String,
                sizeBytes: Int64, modDate: Date?, format: String, confidence: OrphanConfidence) {
        self.path = path
        self.fileName = fileName
        self.artistFolder = artistFolder
        self.albumFolder = albumFolder
        self.sizeBytes = sizeBytes
        self.modDate = modDate
        self.format = format
        self.confidence = confidence
    }
}

/// Esito di una scansione dei file orfani.
public struct OrphanScanResult: Sendable {
    public let orphans: [OrphanFile]
    public let totalFilesScanned: Int
    public let referencedCount: Int
    public let mediaFolder: String

    public var confidentCount: Int { orphans.lazy.filter { $0.confidence.isConfident }.count }
    public var possibleCount: Int { orphans.count - confidentCount }
    public var totalBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeBytes } }
}

/// Esito dello spostamento nel Cestino di un gruppo di orfani.
public struct OrphanTrashResult: Sendable {
    public let trashed: [String]
    public let failed: [(String, String)]
    public let freedBytes: Int64
}

/// Actor che individua i file audio rimasti nella cartella media di Music ma non
/// più referenziati da alcuna traccia della libreria (es. brani eliminati solo da
/// Music senza Cestino, import mai completati) e ne consente lo spostamento nel
/// Cestino in sicurezza.
///
/// Riusa l'infrastruttura di `IndexService` (cartella media, normalizzazione titolo,
/// estensioni audio) per coerenza con la risoluzione dei path durante l'indicizzazione.
public actor OrphanScanService {

    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    // ── Scansione ─────────────────────────────────────────────────────────────

    /// Scansiona la cartella media e restituisce i file orfani.
    /// `progress` viene invocato periodicamente con (file scansionati, orfani trovati).
    public func scan(progress: @Sendable @escaping (Int, Int) -> Void) async throws -> OrphanScanResult {
        guard let mediaFolder = IndexService.musicMediaFolderURL() else {
            throw MusiFixError.appleScriptError(
                "Cartella media di Music non trovata nelle preferenze (media-folder-url)")
        }
        let mediaPath = mediaFolder.path

        // Path referenziati dal DB, normalizzati (disco NFD vs Music NFC).
        let referenced: Set<String> = try db.read { db in
            let paths = try String.fetchAll(
                db, sql: "SELECT locationPath FROM track WHERE locationPath IS NOT NULL")
            return Set(paths.map { $0.precomposedStringWithCanonicalMapping })
        }

        // Indice titolo normalizzato → (nome, artista) per la classificazione confidenza.
        let titleToTrack: [String: (String, String)] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, artist FROM track")
            var dict: [String: (String, String)] = [:]
            for r in rows {
                let name: String = r["name"] ?? ""
                guard !name.isEmpty else { continue }
                let key = IndexService.normKey(name)
                guard !key.isEmpty else { continue }
                if dict[key] == nil {
                    dict[key] = (name, r["artist"] ?? "")
                }
            }
            return dict
        }

        log.info("Scansione orfani: media=\(mediaPath, privacy: .public), referenziati=\(referenced.count)")

        let walkOut = await Self.walk(
            mediaPath: mediaPath,
            referenced: referenced,
            titleToTrack: titleToTrack,
            progress: progress
        )

        let totalScanned = walkOut.scannedTotal
        let result = OrphanScanResult(
            orphans: walkOut.files.sorted(by: Self.orphanOrder),
            totalFilesScanned: totalScanned,
            referencedCount: walkOut.referencedTotal,
            mediaFolder: mediaPath
        )
        log.info("Scansione orfani completata: \(result.orphans.count) orfani su \(totalScanned) file (\(result.referencedCount) referenziati)")
        return result
    }

    /// Ordine di presentazione: prima gli orfani ad alta confidenza, poi per cartella e nome.
    private static func orphanOrder(_ a: OrphanFile, _ b: OrphanFile) -> Bool {
        if a.confidence.isConfident != b.confidence.isConfident {
            return a.confidence.isConfident   // confident prima
        }
        if a.artistFolder != b.artistFolder { return a.artistFolder < b.artistFolder }
        if a.albumFolder != b.albumFolder { return a.albumFolder < b.albumFolder }
        return a.fileName < b.fileName
    }

    /// Risultato grezzo del walk filesystem (incluso conteggi).
    private struct WalkOutput: Sendable {
        var files: [OrphanFile]
        var scannedTotal: Int
        var referencedTotal: Int
    }

    /// Walk della cartella media in un task detached (DirectoryEnumerator non-Sendable).
    /// Solo `stat` su ogni file: nessuna decodifica audio → veloce.
    private static func walk(
        mediaPath: String,
        referenced: Set<String>,
        titleToTrack: [String: (String, String)],
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async -> WalkOutput {
        await Task.detached(priority: .userInitiated) {
            var files: [OrphanFile] = []
            var scanned = 0
            var referencedHit = 0
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: mediaPath),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return WalkOutput(files: [], scannedTotal: 0, referencedTotal: 0)
            }

            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard IndexService.audioExtensions.contains(ext) else { continue }

                let path = fileURL.path
                // Salta i file in coda d'import ("Automatically Add to Music/iTunes"):
                // non sono orfani, sono in attesa di essere importati da Music.
                if path.contains("/Automatically Add to ") { continue }

                let rv = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard rv?.isRegularFile == true else { continue }

                scanned += 1

                if referenced.contains(path.precomposedStringWithCanonicalMapping) {
                    referencedHit += 1
                } else {
                    let stem = fileURL.deletingPathExtension().lastPathComponent
                    let (_, title) = IndexService.parseTrackAndTitle(stem: stem)
                    let confidence: OrphanConfidence
                    if let match = titleToTrack[IndexService.normKey(title)] {
                        confidence = .possibleMatch(track: match.0, artist: match.1)
                    } else {
                        confidence = .confident
                    }
                    let albumFolder = fileURL.deletingLastPathComponent().lastPathComponent
                    let artistFolder = fileURL.deletingLastPathComponent()
                        .deletingLastPathComponent().lastPathComponent
                    files.append(OrphanFile(
                        path: path,
                        fileName: fileURL.lastPathComponent,
                        artistFolder: artistFolder,
                        albumFolder: albumFolder,
                        sizeBytes: Int64(rv?.fileSize ?? 0),
                        modDate: rv?.contentModificationDate,
                        format: ext,
                        confidence: confidence
                    ))
                }

                if scanned % 500 == 0 { progress(scanned, files.count) }
            }
            progress(scanned, files.count)
            return WalkOutput(files: files, scannedTotal: scanned, referencedTotal: referencedHit)
        }.value
    }

    // ── Spostamento nel Cestino ───────────────────────────────────────────────

    /// Sposta nel Cestino i file orfani indicati. Operazione reversibile dall'utente
    /// dal Cestino macOS. Raccoglie i fallimenti per-file senza interrompere il resto.
    public func trashOrphans(_ files: [OrphanFile]) async throws -> OrphanTrashResult {
        var trashed: [String] = []
        var failed: [(String, String)] = []
        var freed: Int64 = 0
        let fm = FileManager.default

        for f in files {
            let url = URL(fileURLWithPath: f.path)
            guard fm.fileExists(atPath: f.path) else {
                failed.append((f.path, "File non più presente"))
                continue
            }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.append(f.path)
                freed += f.sizeBytes
                log.info("Orfano spostato nel Cestino: \(f.path, privacy: .public)")
            } catch {
                failed.append((f.path, error.localizedDescription))
                log.error("Spostamento nel Cestino fallito [\(f.path, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
        }
        return OrphanTrashResult(trashed: trashed, failed: failed, freedBytes: freed)
    }
}
