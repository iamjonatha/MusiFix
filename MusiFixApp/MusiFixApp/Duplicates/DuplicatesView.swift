import SwiftUI
import MusiFixCore
import Persistence

/// Sheet per la ricerca e gestione dei duplicati.
/// Tab metadati (F4.3) e tab fingerprint (F4.4 — richiede calcolo preliminare).
struct DuplicatesView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var selectedTab = 0
    @State private var metaGroups: [DuplicateGroup] = []
    @State private var fpGroups: [DuplicateGroup] = []
    @State private var isSearching = false
    @State private var isComputingFP = false
    @State private var fpProgress: (done: Int, total: Int) = (0, 0)
    @State private var selectedGroup: DuplicateGroup? = nil
    @State private var errorMessage: String? = nil
    @State private var titleThreshold: Double = 0.85
    @State private var fpThreshold: Double = 0.88

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Duplicati").font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            TabView(selection: $selectedTab) {
                metaTab.tabItem { Label("Metadati (\(metaGroups.count))", systemImage: "doc.text.magnifyingglass") }.tag(0)
                fpTab.tabItem   { Label("Fingerprint (\(fpGroups.count))",  systemImage: "waveform.badge.magnifyingglass") }.tag(1)
            }

            Divider()

            HStack {
                Button("Chiudi") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .frame(width: 780, height: 580)
        .onAppear { Task { await searchMeta() } }
    }

    // ── Tab Metadati ──────────────────────────────────────────────────────────

    private var metaTab: some View {
        HSplitView {
            groupList(groups: metaGroups, isLoading: isSearching) {
                HStack {
                    Text("Soglia similarità titolo:")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $titleThreshold, in: 0.5...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", titleThreshold * 100))
                        .font(.caption).monospacedDigit()
                    Button("Cerca") { Task { await searchMeta() } }
                        .disabled(isSearching)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            if let grp = selectedGroup {
                groupDetail(grp)
            } else {
                Text("Seleziona un gruppo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // ── Tab Fingerprint ───────────────────────────────────────────────────────

    private var fpTab: some View {
        HSplitView {
            groupList(groups: fpGroups, isLoading: isSearching) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Soglia Hamming:")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $fpThreshold, in: 0.7...1.0, step: 0.01)
                        Text(String(format: "%.0f%%", fpThreshold * 100))
                            .font(.caption).monospacedDigit()
                        Button("Cerca") { Task { await searchFP() } }
                            .disabled(isSearching || isComputingFP)
                    }
                    if isComputingFP {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Calcolo fingerprint \(fpProgress.done)/\(fpProgress.total)…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Calcola fingerprint (richiede tempo)") {
                            Task { await computeFingerprints() }
                        }
                        .font(.caption)
                        .disabled(isComputingFP)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            if let grp = selectedGroup {
                groupDetail(grp)
            } else {
                Text("Seleziona un gruppo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // ── Lista gruppi ──────────────────────────────────────────────────────────

    @ViewBuilder
    private func groupList(
        groups: [DuplicateGroup],
        isLoading: Bool,
        @ViewBuilder toolbar: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            toolbar()
            Divider()
            if isLoading {
                Spacer(); ProgressView("Ricerca…"); Spacer()
            } else if groups.isEmpty {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundStyle(.green)
                Text("Nessun duplicato trovato.").foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                List(groups, selection: Binding(
                    get: { selectedGroup?.id },
                    set: { id in selectedGroup = groups.first { $0.id == id } }
                )) { grp in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grp.tracks.first?.name ?? "—")
                            .font(.system(size: 12).bold()).lineLimit(1)
                        Text(grp.tracks.map { $0.format.uppercased() }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(String(format: "%.0f%%", grp.score * 100))
                                .font(.caption2).foregroundStyle(.tertiary)
                            if grp.hasFingerprint {
                                Text("FP").font(.caption2.bold())
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 260)
    }

    // ── Dettaglio gruppo ──────────────────────────────────────────────────────

    @ViewBuilder
    private func groupDetail(_ grp: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Confronto").font(.subheadline.bold())
                Spacer()
                Button("Non duplicati") { markNotDup(grp) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            Divider().padding(.top, 6)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(grp.tracks.enumerated()), id: \.offset) { idx, track in
                        TrackComparisonCard(
                            track: track,
                            isKeeper: idx == grp.suggestedKeeper,
                            appState: appState
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    private func searchMeta() async {
        isSearching = true; errorMessage = nil; selectedGroup = nil
        do {
            let thresh = titleThreshold
            metaGroups = try await appState.duplicateService.findMetadataDuplicates(
                titleThreshold: thresh)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func searchFP() async {
        isSearching = true; errorMessage = nil; selectedGroup = nil
        do {
            let thresh = fpThreshold
            fpGroups = try await appState.duplicateService.findFingerprintDuplicates(threshold: thresh)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func computeFingerprints() async {
        isComputingFP = true; fpProgress = (0, 0)
        try? await appState.duplicateService.computeFingerprints { done, total in
            Task { @MainActor in fpProgress = (done, total) }
        }
        isComputingFP = false
        await searchFP()
    }

    private func markNotDup(_ grp: DuplicateGroup) {
        guard grp.tracks.count >= 2 else { return }
        Task {
            try? await appState.duplicateService.markNotDuplicate(
                pid1: grp.tracks[0].persistentID,
                pid2: grp.tracks[1].persistentID
            )
            metaGroups.removeAll { $0.id == grp.id }
            fpGroups.removeAll   { $0.id == grp.id }
            selectedGroup = nil
        }
    }
}

// ── Card singolo brano ────────────────────────────────────────────────────────

private struct TrackComparisonCard: View {
    let track: DBTrack
    let isKeeper: Bool
    let appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Artwork thumbnail
            ArtworkThumbnail(pid: track.persistentID, bridge: appState.bridge)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.name).font(.system(size: 12).bold()).lineLimit(1)
                    if isKeeper {
                        Text("✓ Keeper")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    metaBadge(track.format.uppercased(), color: .blue)
                    if track.bitRate > 0 {
                        metaBadge("\(track.bitRate) kbps", color: .purple)
                    }
                    if track.duration > 0 {
                        metaBadge(formatDuration(track.duration), color: .gray)
                    }
                }
                if let path = track.locationPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(isKeeper ? Color.green.opacity(0.05) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isKeeper ? Color.green.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func metaBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// ── Artwork thumbnail ─────────────────────────────────────────────────────────

private struct ArtworkThumbnail: View {
    let pid: String
    let bridge: any AppleMusicBridge
    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            Task {
                let data = try? await bridge.artwork(persistentID: pid)
                await MainActor.run { if let d = data { image = NSImage(data: d) } }
            }
        }
    }
}
