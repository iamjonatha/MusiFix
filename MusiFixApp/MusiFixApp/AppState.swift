import Foundation
import MusiFixCore
import Persistence
import Combine

@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let dbPath: String
    let bridge: any AppleMusicBridge
    let indexService: IndexService
    let writeService: MetadataWriteService
    let enrichmentService: EnrichmentService
    let normalizationService: NormalizationService
    let albumService: AlbumService
    let duplicateService: DuplicateService
    let deletionService: DeletionService
    let divergenceService: DivergenceService

    @Published var indexProgress: IndexProgress = .init(
        phase: .idle, processed: 0, total: 0, lastSyncDate: nil
    )
    @Published var isIndexing: Bool = false

    private var indexTask: Task<Void, Never>?

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MusiFix", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let path = appSupport.appendingPathComponent("musifixindex.db").path

        self.dbPath = path
        self.db = try! AppDatabase(path: path)
        self.bridge = AppleMusicBridgeFactory.makeBridge()
        self.indexService = IndexService(db: db, bridge: bridge)
        self.writeService = MetadataWriteService(db: db, bridge: bridge)
        self.enrichmentService = EnrichmentService()
        self.normalizationService = NormalizationService(db: db, writeService: writeService)
        self.albumService = AlbumService(db: db, writeService: writeService, enrichment: enrichmentService)
        self.duplicateService = DuplicateService(db: db)
        self.deletionService = DeletionService(db: db, bridge: bridge)
        self.divergenceService = DivergenceService(db: db, bridge: bridge, writeService: writeService)
    }

    func startFullIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do { try await indexService.runFullIndex() }
            catch is CancellationError { print("Indicizzazione annullata dall'utente") }
            catch { print("Index error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
        Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
    }

    func startIncrementalSync() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do { try await indexService.runIncrementalSync() }
            catch is CancellationError { print("Sync annullato dall'utente") }
            catch { print("Sync error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
    }

    /// Annulla l'indicizzazione/sync in corso. La cancellazione è cooperativa:
    /// viene raccolta tra un blocco e il successivo nel fetch da Music.app,
    /// non istantaneamente.
    func cancelIndexing() {
        indexTask?.cancel()
    }
}
