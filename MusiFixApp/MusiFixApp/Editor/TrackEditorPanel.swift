import SwiftUI
import MusiFixCore
import Persistence

/// Pannello laterale di editing per un singolo brano selezionato.
struct TrackEditorPanel: View {
    let track: DBTrack
    let appState: AppState
    var onWritten: () -> Void

    @State private var name: String = ""
    @State private var artist: String = ""
    @State private var albumArtist: String = ""
    @State private var album: String = ""
    @State private var yearText: String = ""
    @State private var genre: String = ""
    @State private var comment: String = ""
    @State private var composer: String = ""
    @State private var trackNumberText: String = ""
    @State private var trackCountText: String = ""
    @State private var discNumberText: String = ""
    @State private var discCountText: String = ""

    @State private var isWriting = false
    @State private var lastError: String? = nil
    @State private var lastSuccess = false
    @State private var showDeletion = false
    @State private var showYearResolution = false
    @State private var webSearch: WebSearchTarget? = nil
    @State private var actionNote: String? = nil
    @State private var trackPlaylists: [String] = []

    var hasChanges: Bool {
        name != track.name || artist != track.artist ||
        albumArtist != track.albumArtist || album != track.album ||
        yearText != (track.year > 0 ? "\(track.year)" : "") ||
        genre != track.genre || comment != track.comment || composer != track.composer ||
        trackNumberText != (track.trackNumber > 0 ? "\(track.trackNumber)" : "") ||
        trackCountText  != (track.trackCount  > 0 ? "\(track.trackCount)"  : "") ||
        discNumberText  != (track.discNumber  > 0 ? "\(track.discNumber)"  : "") ||
        discCountText   != (track.discCount   > 0 ? "\(track.discCount)"   : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Dettagli")
                    .font(.headline)
                Spacer()
                if isWriting { ProgressView().scaleEffect(0.7) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Artwork
            ArtworkEditorView(track: track, appState: appState)
                .frame(height: 130)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        EditorField("Titolo",       $name)
                        EditorField("Artista",      $artist)
                        EditorField("Album Artist", $albumArtist)
                        EditorField("Album",        $album)
                        HStack(alignment: .bottom, spacing: 6) {
                            EditorField("Anno",         $yearText)
                                .overlay(alignment: .trailing) {
                                    yearValidationIcon.padding(.trailing, 6)
                                }
                            Button { showYearResolution = true } label: {
                                Image(systemName: "calendar.badge.clock")
                            }
                            .buttonStyle(.borderless)
                            .help("Recupera l'anno di prima pubblicazione online")
                            .disabled(track.name.isEmpty || isWriting)
                        }
                        EditorField("Genere",       $genre)
                    }
                    Divider().padding(.vertical, 2)
                    Group {
                        EditorField("Commento",  $comment)
                        EditorField("Compositore", $composer)
                    }
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 8) {
                        EditorField("Traccia", $trackNumberText).frame(maxWidth: .infinity)
                        Text("/").foregroundStyle(.tertiary)
                        EditorField("", $trackCountText).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 8) {
                        EditorField("Disco", $discNumberText).frame(maxWidth: .infinity)
                        Text("/").foregroundStyle(.tertiary)
                        EditorField("", $discCountText).frame(maxWidth: .infinity)
                    }

                    if !trackPlaylists.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("In playlist").font(.caption2).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(trackPlaylists, id: \.self) { name in
                                    Text(name)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    if let err = lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    if lastSuccess {
                        Label("Salvato", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let note = actionNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(12)
            }

            Divider()

            // Barra localizza
            HStack(spacing: 6) {
                Button {
                    if let path = track.locationPath {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(track.locationPath == nil)
                .help("Mostra nel Finder")

                Button {
                    Task { try? await appState.bridge.revealInMusic(persistentID: track.persistentID) }
                } label: {
                    Label("Music", systemImage: "music.note")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Mostra in Music")

                Button {
                    webSearch = WebSearchTarget(track: track, engine: .google)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Cerca su Google (finestra interna)")

                Button {
                    webSearch = WebSearchTarget(track: track, engine: .wikipedia)
                } label: {
                    Image(systemName: "book")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Cerca su Wikipedia (finestra interna)")

                Button { copyFileToFolder() } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(track.locationPath == nil)
                .help(track.locationPath == nil
                      ? "Nessun file locale (brano solo-cloud)"
                      : "Copia il file del brano in una cartella…")

                Button { markForVerification() } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Segna come da verificare (playlist WORK/ToCheck)")

                Spacer()

                Button(role: .destructive) { showDeletion = true } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Elimina questo brano")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Barra azioni
            HStack {
                Button("Ripristina") { resetToTrack() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!hasChanges || isWriting)
                Spacer()
                Button("Applica") { applyChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || isWriting || !track.isEditable)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear { resetToTrack() }
        .onChange(of: track.persistentID) { _, _ in resetToTrack() }
        .onChange(of: track.year) { _, _ in resetToTrack() }
        .sheet(isPresented: $showDeletion) {
            DeletionView(
                tracks: [track],
                appState: appState,
                onDeleted: { _ in onWritten() },
                isPresented: $showDeletion
            )
        }
        .sheet(isPresented: $showYearResolution) {
            YearResolutionView(
                track: track,
                appState: appState,
                onApplied: { onWritten() },
                isPresented: $showYearResolution
            )
        }
        .sheet(item: $webSearch) { target in
            WebSearchSheet(track: target.track, engine: target.engine) { webSearch = nil }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var yearValidationIcon: some View {
        let valid = yearText.isEmpty || (Int(yearText) != nil && Int(yearText)! >= 1000 && Int(yearText)! <= 2100)
        return Group {
            if !yearText.isEmpty && !valid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private func resetToTrack() {
        name          = track.name
        artist        = track.artist
        albumArtist   = track.albumArtist
        album         = track.album
        yearText      = track.year > 0 ? "\(track.year)" : ""
        genre         = track.genre
        comment       = track.comment
        composer      = track.composer
        trackNumberText = track.trackNumber > 0 ? "\(track.trackNumber)" : ""
        trackCountText  = track.trackCount  > 0 ? "\(track.trackCount)"  : ""
        discNumberText  = track.discNumber  > 0 ? "\(track.discNumber)"  : ""
        discCountText   = track.discCount   > 0 ? "\(track.discCount)"   : ""
        lastError = nil
        lastSuccess = false
        actionNote = nil
        trackPlaylists = (try? appState.db.read { db in
            try PlaylistDAO.playlistNamesForTrack(pid: track.persistentID, in: db)
        }) ?? []
    }

    private func copyFileToFolder() {
        guard let path = track.locationPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Copia qui"
        panel.message = "Scegli la cartella di destinazione del file"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        actionNote = "Copio…"
        Task {
            do {
                let r = try await appState.fileCopyService.copyFiles(sourcePaths: [path], to: dest)
                await MainActor.run {
                    if r.copied > 0 { actionNote = "File copiato in \u{201C}\(dest.lastPathComponent)\u{201D}." }
                    else if r.missing > 0 { actionNote = "File non trovato sul disco." }
                    else { actionNote = "Copia non riuscita." }
                }
            } catch {
                await MainActor.run { actionNote = "Errore copia: \(error.localizedDescription)" }
            }
        }
    }

    private func markForVerification() {
        let pid = track.persistentID
        actionNote = "Aggiungo a WORK/ToCheck…"
        Task {
            do {
                let r = try await appState.playlistService.markForVerification([pid])
                await MainActor.run {
                    actionNote = r.added > 0
                        ? "Aggiunto a WORK/ToCheck."
                        : (r.skipped > 0 ? "Già in WORK/ToCheck." : "Nessuna modifica.")
                }
            } catch {
                await MainActor.run { actionNote = "Errore: \(error.localizedDescription)" }
            }
        }
    }

    private func buildUpdate() -> TrackMetadataUpdate {
        TrackMetadataUpdate(
            name:        name        != track.name        ? name        : nil,
            artist:      artist      != track.artist      ? artist      : nil,
            albumArtist: albumArtist != track.albumArtist ? albumArtist : nil,
            album:       album       != track.album       ? album       : nil,
            year:        yearText != (track.year > 0 ? "\(track.year)" : "")
                            ? (Int(yearText) ?? (yearText.isEmpty ? 0 : nil)) : nil,
            genre:       genre       != track.genre       ? genre       : nil,
            comment:     comment     != track.comment     ? comment     : nil,
            composer:    composer    != track.composer    ? composer    : nil,
            trackNumber: trackNumberText != (track.trackNumber > 0 ? "\(track.trackNumber)" : "")
                            ? Int(trackNumberText) : nil,
            trackCount:  trackCountText  != (track.trackCount  > 0 ? "\(track.trackCount)"  : "")
                            ? Int(trackCountText) : nil,
            discNumber:  discNumberText  != (track.discNumber  > 0 ? "\(track.discNumber)"  : "")
                            ? Int(discNumberText) : nil,
            discCount:   discCountText   != (track.discCount   > 0 ? "\(track.discCount)"   : "")
                            ? Int(discCountText) : nil
        )
    }

    private func applyChanges() {
        guard hasChanges, !isWriting else { return }
        let update = buildUpdate()
        let pid = track.persistentID
        isWriting = true
        lastError = nil
        lastSuccess = false
        Task {
            do {
                let result = try await appState.writeService.write(update, for: pid)
                await MainActor.run {
                    isWriting = false
                    if result.allSucceeded {
                        lastSuccess = true
                        onWritten()
                    } else if let (_, msg) = result.failed.first {
                        lastError = msg
                    }
                }
            } catch {
                await MainActor.run {
                    isWriting = false
                    lastError = error.localizedDescription
                }
            }
        }
    }
}

// ── Campo form ────────────────────────────────────────────────────────────────

private struct EditorField: View {
    let label: String
    @Binding var value: String

    init(_ label: String, _ value: Binding<String>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField("", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}
