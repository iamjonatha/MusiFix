import SwiftUI
import WebKit
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

    enum ViewMode { case tracks, albums, playlists }
    /// Album su cui posizionarsi passando alla vista album dal menu contestuale brani.
    @State private var albumFocusKey: String?
    @State private var showDivergence = false
    @State private var showEditor = true
    @State private var availableGenres: [String] = []
    @State private var availableYears: [Int] = []
    @State private var showYearFilterPopover = false
    @State private var markSinglePIDs: [String] = []
    @State private var showMarkSingleConfirm = false
    @State private var setPosition1of1PIDs: [String] = []
    @State private var showSetPosition1of1Confirm = false
    @State private var webSearchTarget: WebSearchTarget?
    @State private var playlistFeedback: String?
    @State private var actionFeedback: String?
    @State private var playlistScanDone = true
    @State private var artworkScanDone = true
    @State private var showAutoSyncSettings = false

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

                if let webTrack = selectedTrack {
                    Button {
                        webSearchTarget = WebSearchTarget(track: webTrack)
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .help("Cerca su Google (titolo · artista · anno) in una finestra interna")
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
                    Image(systemName: "list.bullet.rectangle.portrait").tag(ViewMode.playlists)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .help("Alterna vista brani / album / playlist")

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
                Button("Scansiona playlist") { appState.startPlaylistScan() }
                    .disabled(appState.isIndexing)
                    .help("Legge da Music le playlist normali (escluse le smart), popola la Vista Playlist e marca i brani che non appartengono a nessuna.")

                Button { showAutoSyncSettings.toggle() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                }
                .help("Sincronizzazione automatica in background")
                .popover(isPresented: $showAutoSyncSettings, arrowEdge: .bottom) {
                    AutoSyncSettingsPopover { appState.configureAutoSync() }
                }
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

                // Filtro anno/periodo (di pubblicazione)
                Button {
                    showYearFilterPopover.toggle()
                } label: {
                    Label(yearFilterLabel(browser.filter), systemImage: "calendar.badge.clock")
                        .frame(minWidth: 70, alignment: .leading)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Filtra per anno o periodo")
                .popover(isPresented: $showYearFilterPopover, arrowEdge: .bottom) {
                    YearFilterPopover(availableYears: availableYears, currentFilter: browser.filter) { newFilter in
                        browser.filter = newFilter
                        browser.loadInitialPage(db: appState.db)
                        showYearFilterPopover = false
                    }
                }

                Divider().frame(height: 16)

                // Raggruppa per anno di pubblicazione
                Button {
                    browser.setGroupByYear(!browser.groupByYear, db: appState.db)
                } label: {
                    Image(systemName: "rectangle.grid.1x2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(browser.groupByYear ? Color.accentColor : Color.secondary)
                .help("Raggruppa i brani per anno di pubblicazione")

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

                // Filtro ignorati in MusiFix
                Button {
                    browser.filter = (browser.filter == .ignored) ? .none : .ignored
                    browser.loadInitialPage(db: appState.db)
                } label: {
                    Image(systemName: "nosign")
                }
                .buttonStyle(.plain)
                .foregroundStyle(browser.filter == .ignored ? Color.accentColor : Color.secondary)
                .help("Mostra solo brani/album ignorati in MusiFix")

                Divider().frame(height: 16)

                // Filtro non in playlist (con opzione "solo singoli/album incompleti")
                Menu {
                    Button {
                        browser.filter = (browser.filter == .notInAnyPlaylist) ? .none : .notInAnyPlaylist
                        browser.loadInitialPage(db: appState.db)
                    } label: {
                        Label("Non in nessuna playlist", systemImage:
                            browser.filter == .notInAnyPlaylist ? "checkmark" : "list.bullet.rectangle")
                    }
                    Button {
                        browser.filter = (browser.filter == .notInPlaylistIncompleteOnly)
                            ? .none : .notInPlaylistIncompleteOnly
                        browser.loadInitialPage(db: appState.db)
                    } label: {
                        Label("Solo singoli / album incompleti", systemImage:
                            browser.filter == .notInPlaylistIncompleteOnly ? "checkmark" : "rectangle.stack.badge.minus")
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(
                    (browser.filter == .notInAnyPlaylist || browser.filter == .notInPlaylistIncompleteOnly)
                        ? Color.accentColor : Color.secondary)
                .help("Brani non in playlist. La seconda voce esclude i brani di album completi (richiede \u{201C}Scansiona playlist\u{201D}).")

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
                        },
                        onSetIgnore: { pids, ignore in setIgnore(pids: pids, ignore: ignore) },
                        onSetAlbumIgnore: { track, ignore in setAlbumIgnore(track: track, ignore: ignore) },
                        onWebSearch: { track, engine in webSearchTarget = WebSearchTarget(track: track, engine: engine) },
                        onOpenAlbumView: { track in
                            albumFocusKey = IgnoreService.albumKey(
                                albumArtist: track.albumArtist, artist: track.artist, album: track.album)
                            viewMode = .albums
                        },
                        onAddToPlaylist: { pids, playlistID in addToPlaylist(pids: pids, playlistID: playlistID) },
                        onCopyFiles: { pids in copyFiles(pids: pids) },
                        onMarkForVerification: { pids in markForVerification(pids: pids) }
                    )
                    .frame(minWidth: 500)
                    .overlay { scanHintOverlay }

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
                }, searchText: searchText, focusAlbumKey: albumFocusKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .playlists:
                PlaylistsView(
                    appState: appState,
                    onCopyFiles: { pids, playlistName in
                        copyFiles(pids: pids, defaultFolderName: playlistName)
                    },
                    onScanRequested: { appState.startPlaylistScan() }
                )
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
            availableYears = (try? appState.db.read { db in
                try TrackDAO.fetchDistinctYears(in: db)
            }) ?? []
            reloadIgnored()
            reloadHighlightSets()
            reloadPlaylists()
            reloadScanStatus()
        }
        .onChange(of: appState.isIndexing) { _, indexing in
            // A fine scansione (playlist/copertine) ricarica le set di evidenziazione.
            if !indexing {
                reloadHighlightSets()
                reloadScanStatus()
            }
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
        .sheet(item: $webSearchTarget) { target in
            WebSearchSheet(track: target.track, engine: target.engine) { webSearchTarget = nil }
        }
        .alert("Aggiunta a playlist", isPresented: Binding(
            get: { playlistFeedback != nil }, set: { if !$0 { playlistFeedback = nil } }
        )) {
            Button("OK", role: .cancel) { playlistFeedback = nil }
        } message: {
            Text(playlistFeedback ?? "")
        }
        .alert("MusiFix", isPresented: Binding(
            get: { actionFeedback != nil }, set: { if !$0 { actionFeedback = nil } }
        )) {
            Button("OK", role: .cancel) { actionFeedback = nil }
        } message: {
            Text(actionFeedback ?? "")
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

    /// Overlay istruttivo quando un filtro richiede una scansione non ancora eseguita.
    @ViewBuilder
    private var scanHintOverlay: some View {
        if browser.tracks.isEmpty {
            if (browser.filter == .notInAnyPlaylist || browser.filter == .notInPlaylistIncompleteOnly),
               !playlistScanDone {
                scanHint(icon: "list.bullet.rectangle",
                         text: "Per elencare i brani non in playlist esegui prima \u{201C}Scansiona playlist\u{201D}.",
                         button: "Scansiona playlist") { appState.startPlaylistScan() }
            } else if browser.filter == .missingArtwork, !artworkScanDone {
                scanHint(icon: "photo.badge.exclamationmark",
                         text: "Per filtrare i brani senza copertina esegui prima \u{201C}Scansiona copertine\u{201D}.",
                         button: "Scansiona copertine") { appState.startArtworkScan() }
            }
        }
    }

    private func scanHint(icon: String, text: String, button: String,
                          action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(appState.isIndexing)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Aggiorna i flag "scansione eseguita" per gli empty-state guidati.
    private func reloadScanStatus() {
        playlistScanDone = (try? appState.db.read { try TrackDAO.playlistScanDone(in: $0) }) ?? true
        artworkScanDone = (try? appState.db.read { try TrackDAO.artworkScanDone(in: $0) }) ?? true
    }

    /// Ricarica l'elenco delle playlist utente per il menu "Aggiungi a playlist".
    private func reloadPlaylists() {
        Task {
            let tree = (try? await appState.playlistService.playlistTree()) ?? []
            await MainActor.run { browser.playlists = tree }
        }
    }

    /// Aggiunge i brani indicati alla playlist scelta e mostra l'esito (con de-dup).
    private func addToPlaylist(pids: [String], playlistID: String) {
        Task {
            do {
                let r = try await appState.playlistService.addTracks(pids, toPlaylistID: playlistID)
                var parts: [String] = []
                if r.added > 0   { parts.append("\(r.added) aggiunti") }
                if r.skipped > 0 { parts.append("\(r.skipped) già presenti") }
                if r.failed > 0  { parts.append("\(r.failed) non riusciti") }
                let msg = parts.isEmpty ? "Nessuna modifica." : parts.joined(separator: ", ") + "."
                await MainActor.run { playlistFeedback = msg }
            } catch {
                await MainActor.run { playlistFeedback = "Errore: \(error.localizedDescription)" }
            }
        }
    }

    /// Copia i file locali dei brani indicati in una cartella scelta dall'utente.
    private func copyFiles(pids: [String], defaultFolderName: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Copia qui"
        panel.message = "Scegli la cartella di destinazione dei file"
        guard panel.runModal() == .OK, var dest = panel.url else { return }
        // Per la vista playlist si propone una sottocartella col nome della playlist.
        if let name = defaultFolderName, !name.isEmpty {
            dest = dest.appendingPathComponent(sanitizeFolderName(name), isDirectory: true)
        }
        let paths = (try? appState.db.read { db in
            try TrackDAO.fetchLocalPaths(pids: pids, in: db)
        }) ?? []
        guard !paths.isEmpty else {
            actionFeedback = "Nessun file locale da copiare (brani solo-cloud)."
            return
        }
        let finalDest = dest
        Task {
            do {
                let r = try await appState.fileCopyService.copyFiles(sourcePaths: paths, to: finalDest)
                var parts = ["\(r.copied) copiati"]
                if r.missing > 0 { parts.append("\(r.missing) senza file") }
                if r.failed > 0 { parts.append("\(r.failed) falliti") }
                await MainActor.run {
                    actionFeedback = parts.joined(separator: ", ") + " in \u{201C}\(finalDest.lastPathComponent)\u{201D}."
                }
            } catch {
                await MainActor.run { actionFeedback = "Errore copia: \(error.localizedDescription)" }
            }
        }
    }

    /// Rende un nome playlist sicuro come nome cartella (rimuove separatori).
    private func sanitizeFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Playlist" : cleaned
    }

    /// Segna i brani come "da verificare": li aggiunge alla playlist WORK/ToCheck.
    private func markForVerification(pids: [String]) {
        Task {
            do {
                let r = try await appState.playlistService.markForVerification(pids)
                var parts: [String] = []
                if r.added > 0   { parts.append("\(r.added) aggiunti") }
                if r.skipped > 0 { parts.append("\(r.skipped) già presenti") }
                if r.failed > 0  { parts.append("\(r.failed) non riusciti") }
                let msg = parts.isEmpty ? "Nessuna modifica." : parts.joined(separator: ", ") + "."
                await MainActor.run {
                    actionFeedback = "Playlist \u{201C}WORK/ToCheck\u{201D}: " + msg
                    reloadPlaylists()
                }
            } catch {
                await MainActor.run { actionFeedback = "Errore: \(error.localizedDescription)" }
            }
        }
    }

    /// Ricarica le set per l'evidenziazione condizionale (non in playlist / senza copertina).
    private func reloadHighlightSets() {
        let np = (try? appState.db.read { db in try TrackDAO.fetchNotInPlaylistPIDs(in: db) }) ?? []
        let ma = (try? appState.db.read { db in try TrackDAO.fetchMissingArtworkPIDs(in: db) }) ?? []
        browser.notInPlaylistPIDs = Set(np)
        browser.missingArtworkPIDs = Set(ma)
    }

    // ── Ignora in MusiFix (Fase 13) ─────────────────────────────────────────────

    /// Ricarica gli insiemi di brani/album ignorati per l'evidenziazione e i menu.
    private func reloadIgnored() {
        Task {
            browser.ignoredTrackPIDs = (try? await appState.ignoreService.ignoredTrackPIDs()) ?? []
            browser.ignoredAlbumKeys = (try? await appState.ignoreService.ignoredAlbumKeys()) ?? []
        }
    }

    private func setIgnore(pids: [String], ignore: Bool) {
        Task {
            if ignore { try? await appState.ignoreService.ignoreTracks(pids) }
            else      { try? await appState.ignoreService.unignoreTracks(pids) }
            browser.ignoredTrackPIDs = (try? await appState.ignoreService.ignoredTrackPIDs()) ?? []
            browser.loadInitialPage(db: appState.db)
        }
    }

    private func setAlbumIgnore(track: DBTrack, ignore: Bool) {
        Task {
            let head = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            let key = IgnoreService.albumKey(
                albumArtist: track.albumArtist, artist: track.artist, album: track.album)
            if ignore {
                try? await appState.ignoreService.ignoreAlbum(key: key, albumArtist: head, album: track.album)
            } else {
                try? await appState.ignoreService.unignoreAlbum(key: key)
            }
            browser.ignoredAlbumKeys = (try? await appState.ignoreService.ignoredAlbumKeys()) ?? []
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
    case .yearRange(let from, let to): return "Anni: \(from)–\(to)"
    case .ignored:                 return "Ignorati in MusiFix"
    case .notInAnyPlaylist:        return "Non in nessuna playlist"
    case .notInPlaylistIncompleteOnly: return "Non in playlist (solo singoli/album incompleti)"
    }
}

private func genreFilterLabel(_ filter: TrackFilter) -> String {
    if case .genre(let g) = filter { return g }
    return "Genere"
}

private func yearFilterLabel(_ filter: TrackFilter) -> String {
    switch filter {
    case .year(let y): return String(y)
    case .yearRange(let from, let to): return "\(from)–\(to)"
    default: return "Anno"
    }
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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Evidenziazione righe").font(.subheadline.bold())
                Toggle("Non in nessuna playlist", isOn: $settings.highlightNotInPlaylist)
                Toggle("Senza copertina", isOn: $settings.highlightMissingArtwork)
                Text("Richiedono le rispettive scansioni (playlist / copertine).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            Button("Ripristina predefiniti") {
                settings.rowHeight = 22
                settings.fontSize = 12
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 260)
    }
}

struct YearFilterPopover: View {
    let availableYears: [Int]
    let currentFilter: TrackFilter
    let onApply: (TrackFilter) -> Void

    @State private var singleYearText: String = ""
    @State private var fromYearText: String = ""
    @State private var toYearText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filtra per anno")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Anno singolo").font(.subheadline.bold())
                HStack {
                    TextField("es. 1975", text: $singleYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(applySingle)
                    Button("Applica", action: applySingle)
                        .disabled(Int(singleYearText) == nil)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Periodo").font(.subheadline.bold())
                HStack {
                    TextField("Da", text: $fromYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit(applyRange)
                    Text("–")
                    TextField("A", text: $toYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit(applyRange)
                    Button("Applica", action: applyRange)
                        .disabled(Int(fromYearText) == nil || Int(toYearText) == nil)
                }
            }

            if !availableYears.isEmpty {
                Divider()
                Text("Anni disponibili (\(availableYears.count))")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 4) {
                        ForEach(availableYears, id: \.self) { y in
                            Button(String(y)) {
                                onApply(.year(y))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Button("Tutti gli anni") {
                onApply(.none)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            switch currentFilter {
            case .year(let y):
                singleYearText = String(y)
            case .yearRange(let from, let to):
                fromYearText = String(from)
                toYearText = String(to)
            default:
                break
            }
        }
    }

    private func applySingle() {
        guard let y = Int(singleYearText) else { return }
        onApply(.year(y))
    }

    private func applyRange() {
        guard let from = Int(fromYearText), let to = Int(toYearText) else { return }
        onApply(.yearRange(from, to))
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

// ── Ricerca Google embedded (Fase 14) ─────────────────────────────────────────

/// Wrapper Identifiable per presentare la ricerca web via `.sheet(item:)`.
/// Impostazioni della sincronizzazione automatica in background (Fase 20).
struct AutoSyncSettingsPopover: View {
    var onChange: () -> Void
    @AppStorage(AppState.autoSyncEnabledKey) private var enabled = false
    @AppStorage(AppState.autoSyncMinutesKey) private var minutes = AppState.autoSyncDefaultMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sincronizzazione automatica").font(.headline)
            Toggle("Attiva sync in background", isOn: $enabled)
                .onChange(of: enabled) { _, _ in onChange() }
            HStack(spacing: 6) {
                Text("Ogni")
                Stepper(value: $minutes, in: 5...720, step: 5) {
                    Text("\(minutes) min").monospacedDigit()
                }
                .onChange(of: minutes) { _, _ in onChange() }
                .disabled(!enabled)
            }
            Text("Esegue periodicamente: sync incrementale dell'indice, riscansione playlist e copertine. Viene saltata se è già in corso un'indicizzazione manuale.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Motore di ricerca web disponibile nelle finestre interne.
enum WebSearchEngine: Hashable {
    case google
    case wikipedia

    var title: String {
        switch self {
        case .google:    return "Ricerca Google"
        case .wikipedia: return "Ricerca Wikipedia"
        }
    }

    /// Query costruita dai metadati del brano.
    func query(for track: DBTrack) -> String {
        switch self {
        case .google:
            var parts = [track.name, track.artist]
            if track.year > 0 { parts.append(String(track.year)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        case .wikipedia:
            // Su Wikipedia l'anno è rumore; artista + titolo trova l'articolo giusto.
            return [track.name, track.artist].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    func url(for track: DBTrack) -> URL {
        let q = query(for: track)
        switch self {
        case .google:
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            return c.url ?? URL(string: "https://www.google.com")!
        case .wikipedia:
            // Pagina di ricerca standard: nessuna API né limiti di rate.
            var c = URLComponents(string: "https://it.wikipedia.org/w/index.php")!
            c.queryItems = [URLQueryItem(name: "search", value: q)]
            return c.url ?? URL(string: "https://it.wikipedia.org")!
        }
    }
}

struct WebSearchTarget: Identifiable {
    let id = UUID()
    let track: DBTrack
    var engine: WebSearchEngine = .google
}

/// Finestra interna con ricerca web (Google o Wikipedia) sui metadati del brano.
struct WebSearchSheet: View {
    let track: DBTrack
    var engine: WebSearchEngine = .google
    var onClose: () -> Void

    private var query: String { engine.query(for: track) }
    private var url: URL { engine.url(for: track) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(engine.title).font(.headline)
                Text(query).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            WebView(url: url)
        }
        .frame(width: 900, height: 680)
    }
}

/// WKWebView minimale wrappata per SwiftUI. Carica l'URL una sola volta:
/// la navigazione successiva resta interna alla finestra.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Nessun ricaricamento: ogni brano apre una sheet (e quindi una WKWebView) nuova.
    }
}
