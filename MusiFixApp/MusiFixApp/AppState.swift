import Foundation
import MusiFixCore
import Persistence
import Combine

/// Stato globale dell'app — osservabile da tutta la UI.
@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let bridge: any AppleMusicBridge
    let indexService: IndexService

    @Published var indexProgress: IndexProgress = .init(
        phase: .idle, processed: 0, total: 0, lastSyncDate: nil
    )
    @Published var isIndexing: Bool = false

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MusiFix", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("musifixindex.db").path

        // swiftlint:disable force_try
        self.db = try! AppDatabase(path: dbPath)
        // swiftlint:enable force_try
        self.bridge = AppleMusicBridgeFactory.makeBridge()
        self.indexService = IndexService(db: db, bridge: bridge)
    }

    func startFullIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        Task {
            do {
                try await indexService.runFullIndex()
            } catch {
                print("Index error: \(error)")
            }
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
        Task {
            do {
                try await indexService.runIncrementalSync()
            } catch {
                print("Sync error: \(error)")
            }
            await MainActor.run { self.isIndexing = false }
        }
    }
}
