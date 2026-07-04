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

    @State private var searchArtist: String = ""
    @State private var searchAlbum: String = ""
    @State private var searchTitle: String = ""

    @State private var candidates: [ArtworkCandidate] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil
    @State private var selected: ArtworkCandidate? = nil
    @State private var isApplying = false
    @State private var applyProgress: String? = nil
    @State private var autoMode = false
    @State private var autoThreshold = 0.7
    @State private var appliedOK = false
    @State private var showTokenSettings = false
    @AppStorage("discogsToken") private var discogsToken: String = ""

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
                Text("Cerca copertina online")
                    .font(.headline)
                Spacer()
                Button { showTokenSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(discogsToken.isEmpty ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Provider copertine · token Discogs")
                .popover(isPresented: $showTokenSettings, arrowEdge: .bottom) {
                    DiscogsTokenSettings(token: $discogsToken) { newToken in
                        Task {
                            await appState.enrichmentService.setDiscogsToken(newToken)
                            await MainActor.run { startSearch() }
                        }
                    }
                }
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // ── Campi di ricerca ───────────────────────────────────────────────
            VStack(spacing: 6) {
                searchFieldRow(label: "Artista", text: $searchArtist)
                searchFieldRow(label: "Album",   text: $searchAlbum)
                searchFieldRow(label: "Titolo",  text: $searchTitle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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
                .frame(height: 230)
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
                .frame(height: 230)
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
                .frame(height: 230)
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
        .onAppear {
            searchArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            searchAlbum  = track.album
            searchTitle  = track.name
            startSearch()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private func searchFieldRow(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    private func startSearch() {
        isSearching = true
        searchError = nil
        candidates = []
        selected = nil
        appliedOK = false

        let artist = searchArtist
        let album  = searchAlbum
        let title  = searchTitle
        Task {
            let results = await appState.enrichmentService.search(
                albumArtist: artist, album: album, trackTitle: title)
            await MainActor.run {
                isSearching = false
                candidates = results
                if results.isEmpty { searchError = "Nessun risultato per \"\(album)\"." }

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
        let color = artworkProviderColor(provider)
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

    @State private var zoom = false

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
            .overlay(alignment: .topTrailing) {
                Button {
                    zoom = true
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Mostra copertina in grande")
                .popover(isPresented: $zoom, arrowEdge: .trailing) {
                    ArtworkURLZoomPopover(url: candidate.fullURL,
                                         title: candidate.collectionName,
                                         artist: candidate.artistName)
                }
            }

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
            .fill(artworkProviderColor(provider))
            .frame(width: 6, height: 6)
    }
}

// ── Colore per provider (condiviso) ───────────────────────────────────────────

func artworkProviderColor(_ provider: String) -> Color {
    switch provider {
    case "iTunes":      return .pink
    case "MusicBrainz": return .orange
    case "Deezer":      return .purple
    case "Discogs":     return .indigo
    default:            return .gray
    }
}

// ── Impostazioni token Discogs ────────────────────────────────────────────────

private struct DiscogsTokenSettings: View {
    @Binding var token: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider copertine").font(.headline)
            Text("Discogs amplia i risultati (edizioni rare, vinili) ma richiede un token personale gratuito. Generalo da Discogs → Settings → Developers e incollalo qui.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Token Discogs", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Link("Apri Discogs Developers",
                     destination: URL(string: "https://www.discogs.com/settings/developers")!)
                    .font(.caption)
                Spacer()
                Button("Salva") { onSave(token); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// ── Zoom popover per URL candidato ────────────────────────────────────────────

private struct ArtworkURLZoomPopover: View {
    let url: URL
    let title: String
    let artist: String

    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                        .frame(width: 400, height: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48)).foregroundStyle(.tertiary)
                        .frame(width: 400, height: 400)
                case .empty:
                    ProgressView("Caricamento…")
                        .frame(width: 400, height: 400)
                @unknown default:
                    EmptyView()
                }
            }
            Text(title).font(.caption.bold()).lineLimit(1)
            Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
    }
}
