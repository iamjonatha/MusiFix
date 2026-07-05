import Foundation

/// Esito di una copia di file audio verso una cartella.
public struct FileCopyResult: Sendable {
    public let copied: Int      // file copiati con successo
    public let missing: Int     // path noto ma file non presente sul disco
    public let failed: Int      // errore di copia
    public let destination: URL

    public init(copied: Int, missing: Int, failed: Int, destination: URL) {
        self.copied = copied; self.missing = missing; self.failed = failed
        self.destination = destination
    }
}

/// Copia i file audio locali dei brani in una cartella a scelta.
/// I brani senza file locale (cloud-only) vanno filtrati a monte dal chiamante;
/// qui un path inesistente viene contato come `missing`.
public actor FileCopyService {
    public init() {}

    /// Copia i file indicati (percorsi POSIX) nella cartella `destination`.
    /// In caso di conflitto di nome aggiunge un suffisso " (n)" prima dell'estensione.
    /// `progress(done, total)` viene invocato dopo ogni file.
    public func copyFiles(
        sourcePaths: [String],
        to destination: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> FileCopyResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied = 0, missing = 0, failed = 0
        let total = sourcePaths.count
        for (i, path) in sourcePaths.enumerated() {
            try Task.checkCancellation()
            let src = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: src.path) else {
                missing += 1
                progress?(i + 1, total)
                continue
            }
            let dst = Self.uniqueDestination(for: src.lastPathComponent, in: destination, fm: fm)
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                failed += 1
            }
            progress?(i + 1, total)
        }
        return FileCopyResult(copied: copied, missing: missing, failed: failed, destination: destination)
    }

    /// Restituisce un URL non ancora esistente nella cartella, aggiungendo " (n)"
    /// prima dell'estensione se il nome è già occupato.
    nonisolated static func uniqueDestination(
        for filename: String, in folder: URL, fm: FileManager
    ) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
