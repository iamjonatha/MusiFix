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
                        EditorField("Anno",         $yearText)
                            .overlay(alignment: .trailing) {
                                yearValidationIcon.padding(.trailing, 6)
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
                }
                .padding(12)
            }

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
