import SwiftUI
import GRDB
import MusiFixCore
import Persistence

/// Sheet per la ricerca e selezione di copertine online.
/// Supporta modalità assistita (scelta manuale) e automatica (sopra soglia).
struct EnrichmentSearchView: View {
    let track: DBTrack
    let appState: AppState
    var onApplied: () -> Void
    @Binding var isPresented: Bool

    @State private var candidates: [ArtworkCandidate] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil
    @State private var selected: ArtworkCandidate? = nil
    @State private var isApplying = false
    @State private var applyProgress: String? = nil
    @State private var autoMode = false
    @State private var autoThreshold = 0.7
    @State private var appliedOK = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 10)
    ]

    var albumTracks: [DBTrack] {
        (try? appState.db.read { db in
            try DBTrack.filter(
                Column("albumNormalized") == track.albumNormalized &&
                Column("albumArtist") == track.albumArtist
            ).fetchAll(db)
        }) ?? [track]
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cerca copertina online")
                        .font(.headline)
                    Text("\"\(track.album)\" · \(track.albumArtist.isEmpty ? track.artist : track.albumArtist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // ── Modalità ───────────────────────────────────────────────────────
            HStack {
                Toggle("Automatica", isOn: $autoMode)
                    .toggleStyle(.checkbox)
                    .help("Applica automaticamente il primo risultato sopra la soglia")
                if autoMode {
                    Slider(value: $autoThreshold, in: 0.5...1.0, step: 0.05)
                        .frame(width: 100)
                    Text(String(format: "≥ %.0f%%", autoThreshold * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { startSearch() } label: {
                    Label("Cerca di nuovo", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isSearching)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Contenuto ──────────────────────────────────────────────────────
            if isSearching {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Ricerca in corso…")
                    Spacer()
                }
                .frame(height: 280)
            } else if candidates.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    if let err = searchError {
                        Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    } else {
                        Text("Nessun candidato trovato.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(height: 280)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(candidates) { c in
                            CandidateCard(
                                candidate: c,
                                isSelected: selected?.id == c.id,
                                onTap: { selected = c }
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(height: 300)
            }

            Divider()

            // ── Dettaglio candidato selezionato ───────────────────────────────
            if let sel = selected {
                HStack(spacing: 12) {
                    AsyncImage(url: sel.previewURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else { Color(nsColor: .controlBackgroundColor) }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sel.collectionName).font(.system(size: 12).bold()).lineLimit(1)
                        Text(sel.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            providerBadge(sel.provider)
                            if let y = sel.year { Text(String(y)).font(.caption2).foregroundStyle(.tertiary) }
                            Text(String(format: "%.0f%%", sel.score * 100))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // ── Stato applicazione ─────────────────────────────────────────────
            if let prog = applyProgress {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(prog).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            if appliedOK {
                Label("Copertina applicata con successo", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .padding(.horizontal, 16).padding(.vertical, 4)
            }

            Divider()

            // ── Azioni ─────────────────────────────────────────────────────────
            HStack {
                Button("Annulla") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Applica a questo brano") {
                    applyToTrack(pids: [track.persistentID])
                }
                .disabled(selected == nil || isApplying)

                let count = albumTracks.count
                if count > 1 {
                    Button("Applica all'album (\(count) brani)") {
                        applyToTrack(pids: albumTracks.map(\.persistentID))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || isApplying)
                } else {
                    Button("Applica") {
                        applyToTrack(pids: [track.persistentID])
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || isApplying)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear { startSearch() }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func startSearch() {
        isSearching = true
        searchError = nil
        candidates = []
        selected = nil
        appliedOK = false

        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        let album = track.album
        Task {
            let results = await appState.enrichmentService.search(albumArtist: artist, album: album)
            await MainActor.run {
                isSearching = false
                candidates = results
                if results.isEmpty { searchError = "Nessun risultato per \"\(album)\"." }

                // Modalità automatica
                if autoMode, let best = results.first, best.score >= autoThreshold {
                    selected = best
                    applyToTrack(pids: [track.persistentID])
                }
            }
        }
    }

    private func applyToTrack(pids: [String]) {
        guard let candidate = selected else { return }
        isApplying = true
        appliedOK = false
        applyProgress = "Scarico immagine…"

        Task {
            do {
                let data = try await appState.enrichmentService.fetchImageData(from: candidate.fullURL)
                var done = 0
                for pid in pids {
                    await MainActor.run { applyProgress = "Applico \(done + 1)/\(pids.count)…" }
                    _ = try await appState.writeService.setArtwork(data, for: pid)
                    done += 1
                }
                await MainActor.run {
                    isApplying = false
                    applyProgress = nil
                    appliedOK = true
                    onApplied()
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    applyProgress = nil
                    searchError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func providerBadge(_ provider: String) -> some View {
        let color: Color = provider == "iTunes" ? .pink : .orange
        Text(provider)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// ── Card candidato ────────────────────────────────────────────────────────────

private struct CandidateCard: View {
    let candidate: ArtworkCandidate
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            AsyncImage(url: candidate.previewURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                case .empty:
                    ProgressView().scaleEffect(0.7)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 140, height: 140)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            HStack(spacing: 4) {
                providerDot(candidate.provider)
                if let y = candidate.year {
                    Text(String(y)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.0f%%", candidate.score * 100))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 140)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onTap() }
        .onTapGesture { onTap() }
    }

    private func providerDot(_ provider: String) -> some View {
        Circle()
            .fill(provider == "iTunes" ? Color.pink : Color.orange)
            .frame(width: 6, height: 6)
    }
}
