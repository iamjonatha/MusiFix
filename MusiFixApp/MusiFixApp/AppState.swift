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
    let yearResolutionService: YearResolutionService
    let normalizationService: NormalizationService
    let albumService: AlbumService
    let duplicateService: DuplicateService
    let deletionService: DeletionService
    let divergenceService: DivergenceService
    let exportService: ExportService
    let orphanService: OrphanScanService
    let ignoreService: IgnoreService
    let playlistService: PlaylistService
    let playlistAnalysisService: PlaylistAnalysisService
    let advancedPlaylistAnalysisService: AdvancedPlaylistAnalysisService
    let fileCopyService = FileCopyService()
    let mcpProposalService: MCPProposalService
    let mcpServerService: MCPServerService

    @Published var indexProgress: IndexProgress = .init(
        phase: .idle, processed: 0, total: 0, lastSyncDate: nil
    )
    @Published var isIndexing: Bool = false

    /// Stato del server MCP (Fase 25).
    @Published var mcpServerRunning = false
    @Published var mcpPendingProposals = 0
    @Published var mcpServerError: String?

    private var indexTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    /// Chiavi UserDefaults per la sincronizzazione automatica (Fase 20).
    static let autoSyncEnabledKey = "autoSyncEnabled"
    static let autoSyncMinutesKey = "autoSyncMinutes"
    static let autoSyncDefaultMinutes = 30

    /// Chiavi UserDefaults per il server MCP (Fase 25).
    static let mcpPortKey = "mcpServerPort"
    static let mcpTokenKey = "mcpServerToken"
    static let mcpAutoApplyKey = "mcpServerAutoApply"
    static let mcpAutoStartKey = "mcpServerAutoStart"

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
        self.enrichmentService = EnrichmentService(
            discogsToken: UserDefaults.standard.string(forKey: "discogsToken")
        )
        self.yearResolutionService = YearResolutionService()
        self.normalizationService = NormalizationService(db: db, writeService: writeService)
        self.albumService = AlbumService(db: db, writeService: writeService, enrichment: enrichmentService)
        self.duplicateService = DuplicateService(db: db)
        self.deletionService = DeletionService(db: db, bridge: bridge)
        self.divergenceService = DivergenceService(db: db, bridge: bridge, writeService: writeService)
        self.exportService = ExportService(db: db, albumService: albumService)
        self.orphanService = OrphanScanService(db: db)
        self.ignoreService = IgnoreService(db: db)
        self.playlistService = PlaylistService(bridge: bridge)
        self.playlistAnalysisService = PlaylistAnalysisService(db: db)
        self.advancedPlaylistAnalysisService = AdvancedPlaylistAnalysisService(db: db)
        self.mcpProposalService = MCPProposalService(db: db, writeService: writeService)
        self.mcpServerService = MCPServerService(db: db, proposals: mcpProposalService)

        configureAutoSync()
        refreshMCPPendingCount()
        if UserDefaults.standard.bool(forKey: Self.mcpAutoStartKey) {
            startMCPServer()
        }
    }

    // ── Server MCP (Fase 25) ───────────────────────────────────────────────────

    /// Avvia il server MCP con i parametri salvati (porta, token, auto-approvazione).
    func startMCPServer() {
        let defaults = UserDefaults.standard
        let storedPort = defaults.integer(forKey: Self.mcpPortKey)
        let port = UInt16(storedPort > 0 && storedPort <= 65535 ? storedPort : Int(MCPServerService.defaultPort))
        let token = defaults.string(forKey: Self.mcpTokenKey)
        let autoApply = defaults.bool(forKey: Self.mcpAutoApplyKey)
        Task {
            do {
                try await mcpServerService.start(port: port, token: token, autoApply: autoApply)
                self.mcpServerRunning = true
                self.mcpServerError = nil
            } catch {
                self.mcpServerRunning = false
                self.mcpServerError = error.localizedDescription
            }
        }
    }

    func stopMCPServer() {
        Task {
            await mcpServerService.stop()
            self.mcpServerRunning = false
        }
    }

    func toggleMCPServer() {
        if mcpServerRunning { stopMCPServer() } else { startMCPServer() }
    }

    /// Aggiorna il conteggio delle proposte AI in attesa di approvazione.
    func refreshMCPPendingCount() {
        Task {
            let n = (try? await mcpProposalService.pendingCount()) ?? 0
            self.mcpPendingProposals = n
        }
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

    func startArtworkScan() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do {
                let n = try await indexService.scanArtworkPresence()
                print("Scansione copertine completata: \(n) brani")
            }
            catch is CancellationError { print("Scansione copertine annullata") }
            catch { print("Artwork scan error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
        Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
    }

    func startPlaylistScan() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do {
                let n = try await indexService.scanPlaylistFull()
                print("Scansione playlist completata: \(n) brani in playlist")
            }
            catch is CancellationError { print("Scansione playlist annullata") }
            catch { print("Playlist scan error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
        Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
    }

    func startCloudStatusScan() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do {
                let n = try await indexService.scanCloudStatus()
                print("Scansione stato cloud completata: \(n) brani")
            }
            catch is CancellationError { print("Scansione stato cloud annullata") }
            catch { print("Cloud status scan error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
        Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
    }

    /// Recupera la location reale da Music per i brani marcati cloud-only
    /// (file non trovato dall'euristica filesystem) e li rende editabili.
    /// Molto più rapido di un re-index completo.
    func startRepairCloudOnly() {
        guard !isIndexing else { return }
        isIndexing = true
        indexTask = Task {
            do {
                let n = try await indexService.repairCloudOnlyLocations()
                print("Riparati \(n) brani cloud-only")
            }
            catch is CancellationError { print("Riparazione annullata dall'utente") }
            catch { print("Repair error: \(error)") }
            await MainActor.run { self.isIndexing = false }
        }
        Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
    }

    /// Annulla l'indicizzazione/sync in corso. La cancellazione è cooperativa:
    /// viene raccolta tra un blocco e il successivo nel fetch da Music.app,
    /// non istantaneamente.
    func cancelIndexing() {
        indexTask?.cancel()
    }

    // ── Sincronizzazione automatica in background (Fase 20) ────────────────────

    /// (Ri)avvia lo scheduler di sync automatica in base alle preferenze utente.
    /// Da richiamare all'avvio e ogni volta che le impostazioni cambiano.
    func configureAutoSync() {
        autoSyncTask?.cancel()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.autoSyncEnabledKey) else { return }
        let stored = defaults.integer(forKey: Self.autoSyncMinutesKey)
        let minutes = stored > 0 ? stored : Self.autoSyncDefaultMinutes
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.runAutoSyncCycleIfIdle()
            }
        }
    }

    /// Esegue un ciclo di sync automatica se non c'è già un'indicizzazione in corso:
    /// sync incrementale + riscansione playlist + riscansione copertine.
    private func runAutoSyncCycleIfIdle() async {
        guard !isIndexing else { return }
        isIndexing = true
        let progressTask = Task {
            for await progress in await indexService.progressStream() {
                self.indexProgress = progress
            }
        }
        do {
            // runIncrementalSync include già la scansione playlist.
            try await indexService.runIncrementalSync()
            try await indexService.scanArtworkPresence()
            print("Auto-sync completato")
        } catch is CancellationError {
            print("Auto-sync annullato")
        } catch {
            print("Auto-sync error: \(error)")
        }
        progressTask.cancel()
        isIndexing = false
    }
}
