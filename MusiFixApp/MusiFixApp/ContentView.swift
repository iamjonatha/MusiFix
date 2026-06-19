import SwiftUI
import MusiFixCore
import Persistence

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var browser = TrackBrowserViewModel()
    @StateObject private var displaySettings = TableDisplaySettings()
    @State private var showDisplaySettings = false
    @State private var searchText = ""
    @State private var showBatchEditor = false
    @State private var showBatchYear = false
    @State private var showLog = false
    @State private var showNormalization = false
    @State private var showDuplicates = false
    @State private var showOrphans = false
    @State private var showDashboard = false
    @State private var viewMode: ViewMode = .tracks
    @State private var showDeletion = false

    enum ViewMode { case tracks, albums }
    @State private var showDivergence = false
    @State private var showEditor = true
    @State private var availableGenres: [String] = []
    @State private var availableAddedYears: [Int] = []
    @State private var markSinglePIDs: [String] = []
    @State private var showMarkSingleConfirm = false
    @State private var setPosition1of1PIDs: [String] = []
    @State private var showSetPosition1of1Confirm = false

    var selectedTrack: DBTrack? {
        guard browser.selectedPIDs.count == 1 else { return nil }
        return browser.selectedTracks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(.secondary)
                Text("MusiFix").font(.headline)
                Spacer()
                SyncStatusView(
                    progress: appState.indexProgress,
                    isIndexing: appState.isIndexing,
                    onCancel: { appState.cancelIndexing() }
                )

                if !browser.selectedPIDs.isEmpty {
                    Button {
                        showDivergence = true
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .help("Verifica divergenze vs Music.app (\(browser.selectedPIDs.count) selezionati)")
                }

                if browser.selectedPIDs.count > 1 {
                    Button("Modifica \(browser.selectedPIDs.count) brani…") {
                        showBatchEditor = true
                    }
                    Button { showBatchYear = true } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .help("Recupera l'anno di prima pubblicazione (\(browser.selectedPIDs.count) brani)")
                    Button(role: .destructive) { showDeletion = true } label: {
                        Image(systemName: "trash")
                    }
                    .help("Elimina \(browser.selectedPIDs.count) brani selezionati")
                    .foregroundStyle(.red)
                }

                Button { showDashboard = true } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                }
                .help("Statistiche libreria")

                Button { showNormalization = true } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help("Normalizzazione generi e artisti")

                Picker("", selection: $viewMode) {
                    Image(systemName: "music.note.list").tag(ViewMode.tracks)
                    Image(systemName: "square.stack").tag(ViewMode.albums)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .help("Alterna vista brani / album")

                Button { showDuplicates = true } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Trova duplicati")

                Button { showOrphans = true } label: {
                    Image(systemName: "externaldrive.badge.questionmark")
                }
                .help("Trova file audio orfani sul disco non presenti in libreria")

                Button { showLog = true } label: {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Cronologia operazioni")

                Button("Indicizza tutto") { appState.startFullIndex() }
                    .disabled(appState.isIndexing)
                    .help("Riscansione completa della libreria Music.app (25k+ brani). Usa solo al primo avvio o se l'indice è corrotto.")
                Button("Sync") { appState.startIncrementalSync() }
                    .disabled(appState.isIndexing)
                    .help("Aggiorna l'indice con le sole tracce aggiunte/modificate/rimosse dall'ultima sincronizzazione.")
                Button("Ripara cloud-only") { appState.startRepairCloudOnly() }
                    .disabled(appState.isIndexing)
                    .help("Recupera da Music la posizione reale dei brani marcati cloud-only (grigi) il cui file è in realtà scaricato, rendendoli di nuovo editabili.")
                Button("Scansiona copertine") { appState.startArtworkScan() }
                    .disabled(appState.isIndexing)
                    .help("Controlla in Music.app quali brani hanno copertina. Operazione lenta (~2 min). Esegui una volta prima di usare il filtro 'Senza copertina'.")
                Button("Scansiona stato cloud") { appState.startCloudStatusScan() }
                    .disabled(appState.isIndexing)
                    .help("Legge da Music lo stato iCloud (Abbinato/Caricato/Acquistato/Apple Music) e popola i relativi filtri. Veloce; rieseguila se lo stato dei brani cambia.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // ── Search bar + filtro stato ──────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Cerca brano, artista, album…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _, q in
                        browser.search(query: q, db: appState.db)
                    }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }

                Divider().frame(height: 16)

                // Menu filtro stato cloud
                Menu {
                    Button {
                        browser.filter = .none
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Tutti", systemImage: "music.note.list") }

                    Divider()

                    Button {
                        browser.filter = .localOnly
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Locale", systemImage: "checkmark.circle") }

                    Button {
                        browser.filter = .cloudOnly
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Solo cloud (tutti)", systemImage: "cloud") }

                    Divider()

                    Button {
                        browser.filter = .cloudStatus("kMat")
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Abbinato", systemImage: "arrow.triangle.2.circlepath") }

                    Button {
                        browser.filter = .cloudStatus("kUpl")
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Caricato", systemImage: "icloud.and.arrow.up") }

                    Button {
                        browser.filter = .cloudStatus("kPur")
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Acquistato", systemImage: "bag") }

                    Button {
                        browser.filter = .cloudStatus("kSub")
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Apple Music", systemImage: "music.note") }
                } label: {
                    Label(cloudFilterLabel(browser.filter), systemImage: cloudFilterIcon(browser.filter))
                        .frame(minWidth: 110, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filtra per stato cloud")

                Divider().frame(height: 16)

                // Menu filtro genere
                Menu {
                    Button {
                        browser.filter = .none
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Tutti i generi", systemImage: "music.note.list") }

                    Divider()

                    ForEach(availableGenres, id: \.self) { g in
                        Button(g) {
                            browser.filter = .genre(g)
                            browser.loadInitialPage(db: appState.db)
                        }
                    }
                } label: {
                    Label(genreFilterLabel(browser.filter), systemImage: "guitars")
                        .frame(minWidth: 80, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filtra per genere")

                Divider().frame(height: 16)

                // Menu filtro anno di aggiunta
                Menu {
                    Button {
                        browser.filter = .none
                        browser.loadInitialPage(db: appState.db)
                    } label: { Label("Tutti gli anni", systemImage: "calendar") }

                    Divider()

                    ForEach(availableAddedYears, id: \.self) { y in
                        Button(String(y)) {
                            browser.filter = .addedYear(y)
                            browser.loadInitialPage(db: appState.db)
                        }
                    }
                } label: {
                    Label(dateFilterLabel(browser.filter), systemImage: "calendar")
                        .frame(minWidth: 70, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filtra per anno di aggiunta")

                Divider().frame(height: 16)

                // Filtro senza copertina
                Button {
                    if browser.filter == .missingArtwork {
                        browser.filter = .none
                    } else {
                        browser.filter = .missingArtwork
                    }
                    browser.loadInitialPage(db: appState.db)
                } label: {
                    Image(systemName: "photo.badge.exclamationmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(browser.filter == .missingArtwork ? Color.accentColor : Color.secondary)
                .help("Filtra brani senza copertina (richiede 'Scansiona copertine')")

                Divider().frame(height: 16)

                // Filtro anno mancante
                Button {
                    browser.filter = (browser.filter == .missingYear) ? .none : .missingYear
                    browser.loadInitialPage(db: appState.db)
                } label: {
                    Image(systemName: "calendar.badge.exclamationmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(browser.filter == .missingYear ? Color.accentColor : Color.secondary)
                .help("Filtra brani senza anno (poi selezionane più d'uno e usa \u{201C}Recupera anno\u{201D})")

                Divider().frame(height: 16)

                Button {
                    showDisplaySettings.toggle()
                } label: {
                    Image(systemName: "textformat.size")
                }
                .buttonStyle(.plain)
                .help("Impostazioni visualizzazione tabella")
                .popover(isPresented: $showDisplaySettings, arrowEdge: .bottom) {
                    TableDisplaySettingsPopover(settings: displaySettings)
                }

                Divider().frame(height: 16)

                Button {
                    showEditor.toggle()
                } label: {
                    Image(systemName: showEditor ? "info.circle.fill" : "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(showEditor ? Color.accentColor : Color.secondary)
                .help(showEditor ? "Nascondi pannello dettaglio" : "Mostra pannello dettaglio")
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // ── Filtro attivo dalla dashboard ─────────────────────────────────
            if browser.filter != .none {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    Text(filterLabel(for: browser.filter))
                        .font(.caption)
                    Spacer()
                    Button {
                        browser.filter = .none
                        browser.loadInitialPage(db: appState.db)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .help("Rimuovi filtro")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))

                Divider()
            }

            // ── Contenuto principale: brani o album ────────────────────────────
            switch viewMode {
            case .tracks:
                HSplitView {
                    TrackTableView(
                        viewModel: browser,
                        displaySettings: displaySettings,
                        db: appState.db,
                        bridge: appState.bridge,
                        onMarkAsSingle: { pids in
                            markSinglePIDs = pids
                            showMarkSingleConfirm = true
                        },
                        onSetPosition1of1: { pids in
                            setPosition1of1PIDs = pids
                            showSetPosition1of1Confirm = true
                        }
                    )
                    .frame(minWidth: 500)

                    if showEditor, let track = selectedTrack {
                        TrackEditorPanel(
                            track: track,
                            appState: appState,
                            onWritten: {
                                browser.loadInitialPage(db: appState.db)
                            }
                        )
                        .frame(minWidth: 260, maxWidth: 340)
                    }
                }
            case .albums:
                AlbumsView(appState: appState, onOpenTracks: { album in
                    browser.filter = .album(album)
                    browser.loadInitialPage(db: appState.db)
                    viewMode = .tracks
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // ── Status bar ─────────────────────────────────────────────────────
            HStack {
                Text("\(browser.totalCount) brani")
                    .font(.caption).foregroundStyle(.secondary)
                if !browser.selectedPIDs.isEmpty {
                    Text("· \(browser.selectedPIDs.count) selezionati")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = appState.indexProgress.lastSyncDate {
                    Text("Ultima sync: \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .onAppear {
            browser.loadInitialPage(db: appState.db)
            availableGenres = (try? appState.db.read { db in
                try TrackDAO.fetchDistinctGenres(in: db)
            }) ?? []
            availableAddedYears = (try? appState.db.read { db in
                try TrackDAO.fetchDistinctAddedYears(in: db)
            }) ?? []
        }
        .sheet(isPresented: $showBatchEditor) {
            BatchEditorView(
                tracks: browser.selectedTracks,
                appState: appState,
                onWritten: { browser.loadInitialPage(db: appState.db) },
                isPresented: $showBatchEditor
            )
        }
        .sheet(isPresented: $showBatchYear) {
            BatchYearResolutionView(
                tracks: browser.selectedTracks,
                appState: appState,
                isPresented: $showBatchYear,
                onApplied: { browser.loadInitialPage(db: appState.db) }
            )
        }
        .sheet(isPresented: $showLog) {
            OperationLogView(
                appState: appState,
                onUndone: { browser.loadInitialPage(db: appState.db) },
                isPresented: $showLog
            )
        }
        .sheet(isPresented: $showNormalization) {
            NormalizationView(appState: appState, isPresented: $showNormalization)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicatesView(appState: appState, isPresented: $showDuplicates)
        }
        .sheet(isPresented: $showOrphans) {
            OrphansView(appState: appState, isPresented: $showOrphans)
        }
        .sheet(isPresented: $showDashboard) {
            DashboardView(
                appState: appState,
                isPresented: $showDashboard,
                onOpenNormalization: { showNormalization = true },
                onOpenDuplicates:    { showDuplicates = true },
                onFilter: { filter in
                    browser.filter = filter
                    browser.loadInitialPage(db: appState.db)
                }
            )
        }
        .sheet(isPresented: $showDeletion) {
            DeletionView(
                tracks: browser.selectedTracks,
                appState: appState,
                onDeleted: { _ in browser.loadInitialPage(db: appState.db) },
                isPresented: $showDeletion
            )
        }
        .sheet(isPresented: $showDivergence) {
            DivergenceView(
                service: appState.divergenceService,
                pids: Array(browser.selectedPIDs),
                isPresented: $showDivergence,
                onApplied: { browser.loadInitialPage(db: appState.db) }
            )
        }
        .confirmationDialog(
            markSinglePIDs.count == 1
                ? "Aggiungere \u{201C}- Single\u{201D} all'album del brano selezionato?"
                : "Aggiungere \u{201C}- Single\u{201D} all'album di \(markSinglePIDs.count) brani?",
            isPresented: $showMarkSingleConfirm,
            titleVisibility: .visible
        ) {
            Button("Segna come Single") { markAsSingle(pids: markSinglePIDs) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Aggiunge \u{201C}- Single\u{201D} all'album e imposta disco 1/1, traccia 1/1. L'operazione e annullabile dalla cronologia.")
        }
        .confirmationDialog(
            setPosition1of1PIDs.count == 1
                ? "Impostare posizione 1/1 e marcare come Single il brano selezionato?"
                : "Impostare posizione 1/1 e marcare come Single \(setPosition1of1PIDs.count) brani?",
            isPresented: $showSetPosition1of1Confirm,
            titleVisibility: .visible
        ) {
            Button("Imposta posizione 1 di 1") { setPosition1of1(pids: setPosition1of1PIDs) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Imposta disco 1/1, traccia 1/1 e aggiunge \u{201C}- Single\u{201D} all'album se non presente. L'operazione e annullabile dalla cronologia.")
        }
    }

    private func markAsSingle(pids: [String]) {
        Task {
            _ = try? await appState.albumService.markAsSingle(pids: pids)
            browser.loadInitialPage(db: appState.db)
        }
    }

    private func setPosition1of1(pids: [String]) {
        Task {
            _ = try? await appState.albumService.markAsSingle(pids: pids)
            browser.loadInitialPage(db: appState.db)
        }
    }
}

private func filterLabel(for filter: TrackFilter) -> String {
    switch filter {
    case .none:                    return ""
    case .missingYear:             return "Anno mancante"
    case .missingArtist:           return "Artista mancante"
    case .missingAlbum:            return "Album mancante"
    case .missingAlbumArtist:      return "Artista album mancante"
    case .missingGenre:            return "Genere mancante"
    case .missingTrackNumber:      return "N. traccia mancante"
    case .missingDiscNumber:       return "N. disco mancante"
    case .multipleAlbumValues:     return "Valori multipli — Album"
    case .multipleAlbumArtistValues: return "Valori multipli — Artista Album"
    case .missingArtwork:          return "Copertina mancante"
    case .cloudOnly:               return "Solo cloud"
    case .localOnly:               return "Solo scaricati"
    case .cloudStatus(let code):   return CloudStatus(code: code).label
    case .genre(let g):            return "Genere: \(g)"
    case .artist(let a):           return "Artista: \(a)"
    case .album(let a):            return "Album: \(a)"
    case .year(let y):             return "Anno: \(y)"
    case .addedYear(let y):        return "Aggiunto nel \(y)"
    }
}

private func genreFilterLabel(_ filter: TrackFilter) -> String {
    if case .genre(let g) = filter { return g }
    return "Genere"
}

private func dateFilterLabel(_ filter: TrackFilter) -> String {
    if case .addedYear(let y) = filter { return String(y) }
    return "Anno"
}

private func cloudFilterLabel(_ filter: TrackFilter) -> String {
    switch filter {
    case .localOnly:               return "Locale"
    case .cloudOnly:               return "Solo cloud"
    case .cloudStatus(let code):   return CloudStatus(code: code).label
    default:                       return "Stato cloud"
    }
}

private func cloudFilterIcon(_ filter: TrackFilter) -> String {
    switch filter {
    case .localOnly:                  return "checkmark.circle"
    case .cloudOnly:                  return "cloud"
    case .cloudStatus("kMat"):        return "arrow.triangle.2.circlepath"
    case .cloudStatus("kUpl"):        return "icloud.and.arrow.up"
    case .cloudStatus("kPur"):        return "bag"
    case .cloudStatus("kSub"):        return "music.note"
    default:                          return "cloud"
    }
}

// ── Popover impostazioni visualizzazione ──────────────────────────────────────

struct TableDisplaySettingsPopover: View {
    @ObservedObject var settings: TableDisplaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Visualizzazione tabella")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Altezza righe")
                    Spacer()
                    Text("\(Int(settings.rowHeight)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.rowHeight, in: 18...44, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Dimensione font")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.fontSize, in: 10...18, step: 1)
            }

            Button("Ripristina predefiniti") {
                settings.rowHeight = 22
                settings.fontSize = 12
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 240)
    }
}

// ── Sync status chip ──────────────────────────────────────────────────────────

struct SyncStatusView: View {
    let progress: IndexProgress
    let isIndexing: Bool
    var onCancel: () -> Void = {}

    var body: some View {
        if isIndexing {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Annulla indicizzazione/sync")
            }
        }
    }

    private var statusLabel: String {
        switch progress.phase {
        case .fetchingFromMusic:
            return progress.total > 0
                ? "Lettura da Music… \(progress.processed)/\(progress.total)"
                : "Lettura da Music…"
        case .enrichingFiles(let c, let t):          return "\(c)/\(t)"
        case .resolvingLocations(let r, let t):      return "Path file… \(r)/\(t)"
        case .rebuildingFTS:                         return "Indice ricerca…"
        case .done:                         return "Completato"
        case .failed(let e):                return "Errore: \(e)"
        default:                            return ""
        }
    }
}
