import SwiftUI
import MusiFixCore
import Persistence

/// Vista Playlist (Fase 19): elenco delle playlist (con cartelle) a sinistra e
/// i brani contenuti a destra, con azione "Copia file in cartella…".
struct PlaylistsView: View {
    let appState: AppState
    /// (pids, nome playlist proposto come cartella) — copia i file dei brani.
    var onCopyFiles: ([String], String) -> Void
    var onScanRequested: () -> Void

    @State private var playlists: [DBPlaylist] = []
    @State private var selectedID: String? = nil
    @State private var tracks: [DBTrack] = []
    @State private var scanDone = true

    private var selectedPlaylist: DBPlaylist? {
        playlists.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if !scanDone {
                emptyState
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    detail
                        .frame(minWidth: 360)
                }
            }
        }
        .onAppear { reload() }
    }

    // ── Sidebar ────────────────────────────────────────────────────────────────

    private var folders: [DBPlaylist] {
        playlists.filter { $0.isFolder }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func children(of folderID: String?) -> [DBPlaylist] {
        playlists.filter { !$0.isFolder && $0.parentID == folderID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            let top = children(of: nil)
            if !top.isEmpty {
                Section("Playlist") {
                    ForEach(top) { playlistRow($0) }
                }
            }
            ForEach(folders) { folder in
                let kids = children(of: folder.id)
                if !kids.isEmpty {
                    Section(folder.name) {
                        ForEach(kids) { playlistRow($0) }
                    }
                }
            }
        }
        .onChange(of: selectedID) { _, _ in loadTracks() }
    }

    private func playlistRow(_ pl: DBPlaylist) -> some View {
        HStack {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            Text(pl.name).lineLimit(1)
        }
        .tag(pl.id)
    }

    // ── Dettaglio ────────────────────────────────────────────────────────────────

    private var detail: some View {
        VStack(spacing: 0) {
            if let pl = selectedPlaylist {
                HStack {
                    Text(pl.name).font(.headline).lineLimit(1)
                    Text("\(tracks.count) brani").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onCopyFiles(tracks.map(\.persistentID), pl.name)
                    } label: {
                        Label("Copia file in cartella…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(tracks.allSatisfy { $0.locationPath == nil })
                    .help("Copia i file locali dei brani in una sottocartella col nome della playlist")
                }
                .padding(10)
                Divider()
                // Intestazione colonne
                HStack(spacing: 8) {
                    Text("Titolo").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Artista").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Album").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                Divider()
                List(tracks, id: \.persistentID) { t in
                    HStack(spacing: 8) {
                        Text(t.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(t.artist).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary).lineLimit(1)
                        Text(t.album).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Seleziona una playlist").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Per vedere le playlist e i brani contenuti esegui prima \u{201C}Scansiona playlist\u{201D}.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button("Scansiona playlist") { onScanRequested() }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isIndexing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // ── Caricamento ──────────────────────────────────────────────────────────────

    func reload() {
        scanDone = (try? appState.db.read { try PlaylistDAO.scanDone(in: $0) }) ?? false
        playlists = (try? appState.db.read { try PlaylistDAO.fetchPlaylists(in: $0) }) ?? []
        if selectedID == nil || !playlists.contains(where: { $0.id == selectedID }) {
            selectedID = children(of: nil).first?.id ?? folders.compactMap { children(of: $0.id).first?.id }.first
        }
        loadTracks()
    }

    private func loadTracks() {
        guard let id = selectedID else { tracks = []; return }
        tracks = (try? appState.db.read { try PlaylistDAO.tracksInPlaylist(id: id, in: $0) }) ?? []
    }
}
