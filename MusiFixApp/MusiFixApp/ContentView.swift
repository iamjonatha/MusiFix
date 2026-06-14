import SwiftUI
import MusiFixCore
import Persistence

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var browser = TrackBrowserViewModel()
    @State private var searchText = ""
    @State private var showBatchEditor = false
    @State private var showLog = false

    var selectedTrack: DBTrack? {
        guard browser.selectedPIDs.count == 1,
              let pid = browser.selectedPIDs.first else { return nil }
        return browser.selectedTracks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(.secondary)
                Text("MusiFix").font(.headline)
                Spacer()
                SyncStatusView(progress: appState.indexProgress, isIndexing: appState.isIndexing)

                if browser.selectedPIDs.count > 1 {
                    Button("Modifica \(browser.selectedPIDs.count) brani…") {
                        showBatchEditor = true
                    }
                }

                Button { showLog = true } label: {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Cronologia operazioni")

                Button("Indicizza tutto") { appState.startFullIndex() }
                    .disabled(appState.isIndexing)
                Button("Sync") { appState.startIncrementalSync() }
                    .disabled(appState.isIndexing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // ── Search bar ─────────────────────────────────────────────────────
            HStack {
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
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // ── Tabella + pannello editor ──────────────────────────────────────
            HSplitView {
                TrackTableView(viewModel: browser, db: appState.db)
                    .frame(minWidth: 500)

                if let track = selectedTrack {
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
        .onAppear { browser.loadInitialPage(db: appState.db) }
        .sheet(isPresented: $showBatchEditor) {
            BatchEditorView(
                tracks: browser.selectedTracks,
                appState: appState,
                onWritten: { browser.loadInitialPage(db: appState.db) },
                isPresented: $showBatchEditor
            )
        }
        .sheet(isPresented: $showLog) {
            OperationLogView(
                appState: appState,
                onUndone: { browser.loadInitialPage(db: appState.db) }
            )
        }
    }
}

// ── Sync status chip ──────────────────────────────────────────────────────────

struct SyncStatusView: View {
    let progress: IndexProgress
    let isIndexing: Bool

    var body: some View {
        if isIndexing {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLabel: String {
        switch progress.phase {
        case .fetchingFromMusic:            return "Lettura da Music…"
        case .enrichingFiles(let c, let t): return "\(c)/\(t)"
        case .rebuildingFTS:                return "Indice ricerca…"
        case .done:                         return "Completato"
        case .failed(let e):                return "Errore: \(e)"
        default:                            return ""
        }
    }
}
