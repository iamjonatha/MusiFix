import SwiftUI
import MusiFixCore
import Persistence

/// Sheet per editing batch di più brani. Mostra anteprima diff obbligatoria prima di applicare.
struct BatchEditorView: View {
    let tracks: [DBTrack]
    let appState: AppState
    var onWritten: () -> Void
    @Binding var isPresented: Bool

    @State private var artist: String = ""
    @State private var albumArtist: String = ""
    @State private var album: String = ""
    @State private var yearText: String = ""
    @State private var genre: String = ""
    @State private var comment: String = ""
    @State private var composer: String = ""

    @State private var overrideArtist = false
    @State private var overrideAlbumArtist = false
    @State private var overrideAlbum = false
    @State private var overrideYear = false
    @State private var overrideGenre = false
    @State private var overrideComment = false
    @State private var overrideComposer = false

    @State private var showDiff = false
    @State private var isWriting = false
    @State private var writeProgress: (done: Int, total: Int) = (0, 0)
    @State private var lastError: String? = nil

    var hasAnyOverride: Bool {
        overrideArtist || overrideAlbumArtist || overrideAlbum ||
        overrideYear || overrideGenre || overrideComment || overrideComposer
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Modifica \(tracks.count) brani")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Form campi batch
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Seleziona i campi da sovrascrivere su tutti i brani selezionati.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BatchField("Artista",      $artist,      $overrideArtist)
                    BatchField("Album Artist", $albumArtist, $overrideAlbumArtist)
                    BatchField("Album",        $album,       $overrideAlbum)
                    BatchField("Anno",         $yearText,    $overrideYear)
                    BatchField("Genere",       $genre,       $overrideGenre)
                    BatchField("Commento",     $comment,     $overrideComment)
                    BatchField("Compositore",  $composer,    $overrideComposer)

                    if let err = lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()

            // Barra azioni
            HStack {
                if isWriting {
                    ProgressView(value: Double(writeProgress.done),
                                 total: Double(max(writeProgress.total, 1)))
                    .frame(width: 120)
                    Text("\(writeProgress.done)/\(writeProgress.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annulla") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Anteprima diff…") { showDiff = true }
                    .disabled(!hasAnyOverride || isWriting)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 440)
        .sheet(isPresented: $showDiff) {
            DiffPreviewView(
                tracks: tracks,
                update: buildUpdate(),
                onConfirm: {
                    showDiff = false
                    applyBatch()
                },
                onCancel: { showDiff = false }
            )
        }
        .onAppear { initFromCommonValues() }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func initFromCommonValues() {
        func common<T: Equatable>(_ kp: KeyPath<DBTrack, T>) -> T? {
            let vals = tracks.map { $0[keyPath: kp] }
            return vals.dropFirst().allSatisfy({ $0 == vals.first! }) ? vals.first : nil
        }
        if let v = common(\.artist)      { artist      = v }
        if let v = common(\.albumArtist) { albumArtist = v }
        if let v = common(\.album)       { album       = v }
        if let v = common(\.genre)       { genre       = v }
        if let v = common(\.comment)     { comment     = v }
        if let v = common(\.composer)    { composer    = v }
        if let v = common(\.year), v > 0 { yearText   = "\(v)" }
    }

    private func buildUpdate() -> TrackMetadataUpdate {
        TrackMetadataUpdate(
            artist:      overrideArtist      ? artist      : nil,
            albumArtist: overrideAlbumArtist ? albumArtist : nil,
            album:       overrideAlbum       ? album       : nil,
            year:        overrideYear        ? (Int(yearText) ?? 0) : nil,
            genre:       overrideGenre       ? genre       : nil,
            comment:     overrideComment     ? comment     : nil,
            composer:    overrideComposer    ? composer    : nil
        )
    }

    private func applyBatch() {
        guard hasAnyOverride, !isWriting else { return }
        let update = buildUpdate()
        let items = tracks.map { (update, $0.persistentID) }
        isWriting = true
        writeProgress = (0, items.count)
        lastError = nil
        Task {
            do {
                // Scrivi uno alla volta per aggiornare il progresso
                var done = 0
                for (u, pid) in items {
                    _ = try await appState.writeService.write(u, for: pid)
                    done += 1
                    await MainActor.run { writeProgress = (done, items.count) }
                }
                await MainActor.run {
                    isWriting = false
                    isPresented = false
                    onWritten()
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

// ── Campo batch con checkbox ──────────────────────────────────────────────────

private struct BatchField: View {
    let label: String
    @Binding var value: String
    @Binding var enabled: Bool

    init(_ label: String, _ value: Binding<String>, _ enabled: Binding<Bool>) {
        self.label = label; self._value = value; self._enabled = enabled
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
            }
        }
    }
}
