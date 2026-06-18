import SwiftUI
import MusiFixCore
import Persistence

/// Vista Album (hub): tracce raggruppate per album, esclusi i singoli.
/// Mostra lo stato di completezza offline (via tag trackCount) e permette
/// di passare ai brani contenuti per l'editing in-place. Vista alternativa
/// al browser dei brani (incorporata, non modale).
struct AlbumsView: View {
    let appState: AppState
    /// Apre i brani dell'album nel browser (filtra + passa alla vista brani).
    var onOpenTracks: (String) -> Void

    @State private var albums: [AlbumGroup] = []
    @State private var storeInfo: [String: DBAlbumStoreInfo] = [:]
    @State private var isLoading = false
    @State private var filter: Filter = .all
    @State private var errorMessage: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanProgress: (done: Int, total: Int)?
    @State private var showCountFix = false
    @State private var showPositionFix = false
    @State private var diffAlbum: AlbumGroup?
    @State private var alignAlbum: AlbumGroup?

    enum Filter: String, CaseIterable, Identifiable {
        case all, incomplete, unknown, complete, mixedCloud
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:        return "Tutti"
            case .incomplete: return "Incompleti"
            case .unknown:    return "Senza tag"
            case .complete:   return "Completi"
            case .mixedCloud: return "Cloud misto"
            }
        }
    }

    private var filtered: [AlbumGroup] {
        switch filter {
        case .all:        return albums
        case .incomplete: return albums.filter { $0.completeness == .incomplete }
        case .unknown:    return albums.filter { $0.completeness == .unknown }
        case .complete:   return albums.filter { $0.completeness == .complete }
        case .mixedCloud: return albums.filter { $0.hasMixedCloudStatus }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                Spacer()
                Text("\(filtered.count) album")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            // ── Verifica online (Fase D) ────────────────────────────────────────
            HStack(spacing: 8) {
                if let p = scanProgress {
                    ProgressView().scaleEffect(0.6)
                    Text("Verifica online… \(p.done)/\(p.total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Interrompi") { scanTask?.cancel() }
                        .font(.caption)
                } else {
                    Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                    Text("Album «senza tag»: \(albums.filter { $0.completeness == .unknown }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Verifica online su iTunes") { startScan() }
                        .font(.caption)
                    Text("(lento: ~3 s per album)").font(.caption2).foregroundStyle(.tertiary)
                    Divider().frame(height: 14)
                    Button("Scrivi conteggi verificati…") { showCountFix = true }
                        .font(.caption)
                        .help("Scrive trackCount/discCount sugli album senza tag risultati completi alla verifica online")
                    Divider().frame(height: 14)
                    Button("Imposta posizione 1 di 1…") { showPositionFix = true }
                        .font(.caption)
                        .help("Imposta disco 1/1 e traccia 1/1 sulle tracce che mancano di numero disco o traccia")
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if isLoading {
                Spacer(); ProgressView("Caricamento album…"); Spacer()
            } else if let err = errorMessage {
                Spacer(); Text(err).foregroundStyle(.red); Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Image(systemName: "square.stack").font(.system(size: 32)).foregroundStyle(.secondary)
                Text("Nessun album in questa categoria.").foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                List(filtered) { album in
                    AlbumRow(album: album, store: storeInfo[album.key], bridge: appState.bridge)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpenTracks(album.album) }
                        .contextMenu {
                            Button("Apri brani per modifica") { onOpenTracks(album.album) }
                            Button("Allinea numeri traccia/disco…") { alignAlbum = album }
                            Button("Confronta durate (caricati)") { diffAlbum = album }
                                .disabled(storeInfo[album.key]?.collectionId == nil)
                        }
                }
            }

            Divider()
            HStack {
                Text("Doppio click su un album per aprirne i brani e modificarli.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        .sheet(isPresented: $showCountFix) {
            AlbumCountFixSheet(appState: appState, isPresented: $showCountFix, onApplied: { load() })
        }
        .sheet(isPresented: $showPositionFix) {
            TrackPositionFixSheet(appState: appState, isPresented: $showPositionFix, onApplied: { load() })
        }
        .sheet(item: $diffAlbum) { album in
            DurationDiffSheet(appState: appState, album: album, onClose: { diffAlbum = nil })
        }
        .sheet(item: $alignAlbum) { album in
            AlbumPositionAlignSheet(appState: appState, album: album, onClose: { alignAlbum = nil; load() })
        }
    }

    private func load() {
        isLoading = true; errorMessage = nil
        Task {
            do {
                let groups = try await appState.albumService.albumGroups()
                let store = try await appState.albumService.storeInfoByKey()
                await MainActor.run { albums = groups; storeInfo = store; isLoading = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isLoading = false }
            }
        }
    }

    private func startScan() {
        scanProgress = (0, 0)
        scanTask = Task {
            let service = appState.albumService
            try? await service.verifyAlbumsOnline { done, total in
                Task { @MainActor in scanProgress = (done, total) }
            }
            // Ricarica la cache aggiornata
            let store = (try? await service.storeInfoByKey()) ?? [:]
            await MainActor.run {
                storeInfo = store
                scanProgress = nil
            }
        }
    }
}

// ── Riga album ─────────────────────────────────────────────────────────────────

private struct AlbumRow: View {
    let album: AlbumGroup
    let store: DBAlbumStoreInfo?
    let bridge: any AppleMusicBridge

    var body: some View {
        HStack(spacing: 10) {
            AlbumArtwork(pid: album.pids.first ?? "", bridge: bridge)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.album).font(.system(size: 13).bold()).lineLimit(1)
                Text(album.albumArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !cloudSummary.isEmpty {
                    Text(cloudSummary)
                        .font(.caption2)
                        .foregroundStyle(album.hasMixedCloudStatus ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            countBadge
            completenessBadge
        }
        .padding(.vertical, 3)
    }

    /// Riepilogo stati iCloud, es. "Abbinato 8 · Caricato 2".
    private var cloudSummary: String {
        album.cloudStatusCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { "\(CloudStatus(code: $0.key).label) \($0.value)" }
            .joined(separator: " · ")
    }

    /// Totale di riferimento: tag se presente, altrimenti il valore dello Store.
    private var effectiveTotal: Int? {
        if album.tagTrackCount > 0 { return album.tagTrackCount }
        return store?.storeTrackCount
    }

    private var countBadge: some View {
        let total = effectiveTotal.map { "\($0)" } ?? "?"
        return Text("\(album.actualCount)/\(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var completenessBadge: some View {
        let (text, color) = badge
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    /// Badge: usa lo stato offline; se «senza tag», deriva dallo Store quando disponibile.
    private var badge: (String, Color) {
        if album.completeness == .unknown {
            guard let s = store else { return ("Senza tag", .gray) }
            if s.matchState != "found" || s.storeTrackCount == nil {
                return ("Non su Store", .gray)
            }
            let total = s.storeTrackCount!
            if album.actualCount == total { return ("Completo ✓Store", .green) }
            return album.actualCount < total ? ("Incompleto ✓Store", .red) : ("Eccesso", .orange)
        }
        switch album.completeness {
        case .complete:   return ("Completo", .green)
        case .incomplete: return ("Incompleto", .red)
        case .excess:     return ("Eccesso", .orange)
        case .unknown:    return ("Senza tag", .gray)
        case .multiDisc:  return ("Multi-disco", .purple)
        }
    }
}

// ── Sheet scrittura conteggi verificati (Fase D-bis) ────────────────────────────

private struct AlbumCountFixSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool
    var onApplied: () -> Void

    @State private var fixes: [AlbumService.AlbumCountFix] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var resultText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scrivi conteggi verificati").font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if isLoading {
                Spacer(); ProgressView("Caricamento candidati…"); Spacer()
            } else if fixes.isEmpty {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundStyle(.green)
                Text("Nessun album completo verificato senza tag.")
                    .foregroundStyle(.secondary).padding(.top, 4)
                Text("Esegui prima la verifica online su iTunes.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            } else {
                HStack {
                    Button(selected.count == fixes.count ? "Deseleziona tutti" : "Seleziona tutti") {
                        selected = selected.count == fixes.count ? [] : Set(fixes.map { $0.id })
                    }.font(.caption)
                    Spacer()
                    Text("\(selected.count)/\(fixes.count) selezionati").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)

                List(fixes) { fix in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(fix.id) },
                            set: { on in if on { selected.insert(fix.id) } else { selected.remove(fix.id) } }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fix.album).font(.system(size: 12).bold()).lineLimit(1)
                            Text(fix.albumArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("→ trackCount \(fix.storeTrackCount)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                    }
                }
            }

            Divider()
            HStack {
                Button("Chiudi") { isPresented = false }.keyboardShortcut(.cancelAction)
                if let r = resultText { Text(r).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isApplying { ProgressView().scaleEffect(0.6) }
                Button("Applica ai selezionati") { apply() }
                    .disabled(selected.isEmpty || isApplying)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .onAppear { load() }
    }

    private func load() {
        isLoading = true
        Task {
            let list = (try? await appState.albumService.completeVerifiedWithoutTag()) ?? []
            await MainActor.run {
                fixes = list
                selected = Set(list.map { $0.id })
                isLoading = false
            }
        }
    }

    private func apply() {
        isApplying = true
        let chosen = fixes.filter { selected.contains($0.id) }
        Task {
            let result = try? await appState.albumService.writeTrackCounts(chosen)
            await MainActor.run {
                isApplying = false
                if let r = result {
                    resultText = "Aggiornate \(r.updated) tracce" + (r.failed > 0 ? ", \(r.failed) errori" : "")
                }
                onApplied()
            }
        }
    }
}

// ── Sheet diff durate caricato vs Store (Fase E) ────────────────────────────────

private struct DurationDiffSheet: View {
    let appState: AppState
    let album: AlbumGroup
    var onClose: () -> Void

    @State private var diffs: [AlbumService.DurationDiff] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Durate: caricato vs Store").font(.headline)
                    Text(album.album).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if isLoading {
                Spacer(); ProgressView("Confronto in corso…"); Spacer()
            } else if diffs.isEmpty {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundStyle(.green)
                Text("Nessuna differenza di durata significativa.")
                    .foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                List(diffs) { d in
                    HStack {
                        Text(d.trackName).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(fmt(d.localDuration)).font(.caption.monospacedDigit())
                        Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(fmt(d.storeDuration)).font(.caption.monospacedDigit()).foregroundStyle(.blue)
                        Text("Δ\(Int(d.deltaSeconds))s")
                            .font(.caption2.bold()).foregroundStyle(.orange)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Divider()
            HStack {
                Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("Locale ↔ Store · soglia 2 s").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
        .onAppear { load() }
    }

    private func fmt(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func load() {
        isLoading = true
        Task {
            let result = (try? await appState.albumService.durationDiffs(for: album)) ?? []
            await MainActor.run { diffs = result; isLoading = false }
        }
    }
}

// ── Sheet fix posizione disco/traccia 1 di 1 ────────────────────────────────────

private struct TrackPositionFixSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool
    var onApplied: () -> Void

    @State private var fixes: [AlbumService.TrackPositionFix] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var resultText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imposta posizione 1 di 1").font(.headline)
                    Text("Disco 1/1 · Traccia 1/1 — solo brani senza numero")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if isLoading {
                Spacer(); ProgressView("Caricamento candidati…"); Spacer()
            } else if fixes.isEmpty {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundStyle(.green)
                Text("Nessun brano con numero disco/traccia mancante.")
                    .foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                HStack {
                    Button(selected.count == fixes.count ? "Deseleziona tutti" : "Seleziona tutti") {
                        selected = selected.count == fixes.count ? [] : Set(fixes.map { $0.id })
                    }.font(.caption)
                    Spacer()
                    Text("\(selected.count)/\(fixes.count) selezionati").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)

                List(fixes) { fix in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(fix.id) },
                            set: { on in if on { selected.insert(fix.id) } else { selected.remove(fix.id) } }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fix.trackName).font(.system(size: 12).bold()).lineLimit(1)
                            Text("\(fix.albumArtist) — \(fix.album)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("→ disco 1/1  traccia 1/1")
                            .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                    }
                }
            }

            Divider()
            HStack {
                Button("Chiudi") { isPresented = false }.keyboardShortcut(.cancelAction)
                if let r = resultText { Text(r).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isApplying { ProgressView().scaleEffect(0.6) }
                Button("Applica ai selezionati") { apply() }
                    .disabled(selected.isEmpty || isApplying)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 500)
        .onAppear { load() }
    }

    private func load() {
        isLoading = true
        Task {
            let list = (try? await appState.albumService.tracksWithMissingPositions()) ?? []
            await MainActor.run {
                fixes = list
                selected = Set(list.map { $0.id })
                isLoading = false
            }
        }
    }

    private func apply() {
        isApplying = true
        let chosen = fixes.filter { selected.contains($0.id) }
        Task {
            let result = try? await appState.albumService.writePositions(chosen)
            await MainActor.run {
                isApplying = false
                if let r = result {
                    resultText = "Aggiornate \(r.updated) tracce" + (r.failed > 0 ? ", \(r.failed) errori" : "")
                }
                onApplied()
            }
        }
    }
}

// ── Sheet allineamento numeri traccia/disco da Store (Fase G) ──────────────────

/// Step 1: scelta edizione Store.  Step 2: mappa di conferma editabile.
private struct AlbumPositionAlignSheet: View {
    let appState: AppState
    let album: AlbumGroup
    var onClose: () -> Void

    // Step 1 — scelta edizione
    @State private var candidates: [EnrichmentService.AlbumLookupCandidate] = []
    @State private var selectedCandidate: EnrichmentService.AlbumLookupCandidate?
    @State private var isLoadingCandidates = true
    @State private var candidateError: String?

    // Step 2 — mappa di conferma
    @State private var alignment: AlbumService.AlbumAlignment?
    @State private var proposals: [AlbumService.PositionProposal] = []
    @State private var isLoadingAlignment = false
    @State private var isApplying = false
    @State private var resultText: String?

    private var step: Int { alignment == nil ? 1 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            // Intestazione
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(step == 1 ? "Scegli edizione Store" : "Mappa numeri traccia/disco")
                        .font(.headline)
                    Text(album.album + " — " + album.albumArtist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if step == 1 {
                editionStep
            } else {
                confirmStep
            }

            Divider()
            footerBar
        }
        .frame(width: 680, height: step == 1 ? 420 : 600)
        .onAppear { loadCandidates() }
    }

    // ── Step 1: scelta edizione ───────────────────────────────────────────────

    @ViewBuilder
    private var editionStep: some View {
        if isLoadingCandidates {
            Spacer(); ProgressView("Ricerca su iTunes…"); Spacer()
        } else if let err = candidateError {
            Spacer(); Text(err).foregroundStyle(.red).padding(); Spacer()
        } else if candidates.isEmpty {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Nessuna edizione trovata su iTunes.").foregroundStyle(.secondary).padding(.top, 4)
            Spacer()
        } else {
            List(candidates, id: \.collectionId) { c in
                HStack(spacing: 10) {
                    Image(systemName: selectedCandidate?.collectionId == c.collectionId
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedCandidate?.collectionId == c.collectionId ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.collectionName).font(.system(size: 12).bold()).lineLimit(1)
                        Text(c.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let y = c.year {
                        Text("\(y)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("\(c.storeTrackCount) tracce")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if c.discCount > 1 {
                        Text("\(c.discCount) dischi")
                            .font(.caption2).foregroundStyle(.purple)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12)).clipShape(Capsule())
                    }
                    scoreBar(c.score)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedCandidate = c }
            }
        }
    }

    private func scoreBar(_ score: Double) -> some View {
        let pct = min(max(score, 0), 1)
        let color: Color = pct >= 0.7 ? .green : pct >= 0.45 ? .orange : .red
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7))
                    .frame(width: g.size.width * pct)
            }
        }
        .frame(width: 50, height: 6)
    }

    // ── Step 2: mappa di conferma ─────────────────────────────────────────────

    @ViewBuilder
    private var confirmStep: some View {
        if isLoadingAlignment {
            Spacer(); ProgressView("Calcolo abbinamenti…"); Spacer()
        } else {
            VStack(spacing: 0) {
                // Legenda
                HStack(spacing: 12) {
                    legendChip("Alta", .green)
                    legendChip("Media", .orange)
                    legendChip("Incerta", .red)
                    legendChip("Senza match", .red)
                    Spacer()
                    Text("\(proposals.filter { $0.proposedTrackNumber != nil }.count)/\(proposals.count) abbinati")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                Divider()

                // Tabella
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Header
                        HStack(spacing: 0) {
                            Text("Brano").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Attuale").frame(width: 90, alignment: .center)
                            Text("Abbinamento Store").frame(width: 170, alignment: .leading)
                            Text("Traccia").frame(width: 56, alignment: .center)
                            Text("Disco").frame(width: 56, alignment: .center)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        Divider()

                        ForEach($proposals) { $p in
                            ProposalRow(proposal: $p)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    private func legendChip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var footerBar: some View {
        HStack {
            Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
            if step == 2 {
                Button("← Cambia edizione") {
                    alignment = nil; proposals = []
                }
                .font(.caption)
            }
            if let r = resultText {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isApplying || isLoadingAlignment { ProgressView().scaleEffect(0.6) }
            if step == 1 {
                Button("Calcola abbinamenti →") { loadAlignment() }
                    .disabled(selectedCandidate == nil || isLoadingCandidates)
                    .keyboardShortcut(.defaultAction)
            } else {
                let writableCount = proposals.filter {
                    $0.proposedTrackNumber != nil && $0.proposedTrackCount != nil &&
                    $0.proposedDiscNumber  != nil && $0.proposedDiscCount  != nil
                }.count
                Button("Scrivi \(writableCount) tracce") { apply() }
                    .disabled(writableCount == 0 || isApplying)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // ── Logica ────────────────────────────────────────────────────────────────

    private func loadCandidates() {
        isLoadingCandidates = true; candidateError = nil
        Task {
            do {
                let list = try await appState.enrichmentService.lookupAlbumCandidates(
                    albumArtist: album.albumArtist, album: album.album)
                await MainActor.run {
                    candidates = list
                    selectedCandidate = list.first
                    isLoadingCandidates = false
                }
            } catch {
                await MainActor.run {
                    candidateError = "Errore: \(error.localizedDescription)"
                    isLoadingCandidates = false
                }
            }
        }
    }

    private func loadAlignment() {
        guard let c = selectedCandidate else { return }
        isLoadingAlignment = true
        Task {
            do {
                let al = try await appState.albumService.proposeAlbumPositions(for: album, candidate: c)
                await MainActor.run {
                    alignment = al
                    proposals = al.proposals
                    isLoadingAlignment = false
                }
            } catch {
                await MainActor.run {
                    candidateError = "Errore: \(error.localizedDescription)"
                    isLoadingAlignment = false
                    alignment = nil
                }
            }
        }
    }

    private func apply() {
        isApplying = true
        let toWrite = proposals
        Task {
            let result = try? await appState.albumService.writeProposedPositions(toWrite)
            await MainActor.run {
                isApplying = false
                if let r = result {
                    resultText = "Scritte \(r.succeeded.count) tracce"
                        + (r.failed.isEmpty ? "" : ", \(r.failed.count) errori")
                }
            }
        }
    }
}

// ── Riga editabile della mappa di conferma ─────────────────────────────────────

private struct ProposalRow: View {
    @Binding var proposal: AlbumService.PositionProposal

    // Stringhe temporanee per i TextField numerici
    @State private var tnStr: String = ""
    @State private var tcStr: String = ""
    @State private var dnStr: String = ""
    @State private var dcStr: String = ""

    var body: some View {
        HStack(spacing: 0) {
            // Nome brano + badge confidenza
            HStack(spacing: 4) {
                confidenceDot
                Text(proposal.trackName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 12)

            // Posizione attuale
            Text(currentPos)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .center)

            // Abbinamento store
            Text(proposal.matchedStoreName ?? "—")
                .font(.system(size: 10)).foregroundStyle(matchColor)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            // Campo traccia/totale
            numField($tnStr, placeholder: "tr") { v in proposal.proposedTrackNumber = v }
            Text("/").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
            numField($tcStr, placeholder: "tot") { v in proposal.proposedTrackCount = v }

            // Campo disco/totale
            numField($dnStr, placeholder: "d") { v in proposal.proposedDiscNumber = v }
            Text("/").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
            numField($dcStr, placeholder: "tot") { v in proposal.proposedDiscCount = v }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .background(rowBackground)
        .onAppear { syncStrings() }
        .onChange(of: proposal.proposedTrackNumber) { _, _ in syncStrings() }
    }

    private func numField(_ str: Binding<String>, placeholder: String, onCommit: @escaping (Int?) -> Void) -> some View {
        TextField(placeholder, text: str)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 32)
            .textFieldStyle(.roundedBorder)
            .onSubmit { onCommit(Int(str.wrappedValue)) }
            .onChange(of: str.wrappedValue) { _, v in onCommit(Int(v)) }
    }

    private var currentPos: String {
        let tn = proposal.currentTrackNumber, tc = proposal.currentTrackCount
        let dn = proposal.currentDiscNumber,  dc = proposal.currentDiscCount
        if tn == 0 && dn == 0 { return "—" }
        if dc > 1 { return "D\(dn) T\(tn)/\(tc)" }
        return "\(tn)/\(tc)"
    }

    private var matchColor: Color {
        switch proposal.confidence {
        case .high:      return .primary
        case .medium:    return .orange
        case .uncertain: return .red
        case .unmatched: return .red
        }
    }

    @ViewBuilder
    private var confidenceDot: some View {
        let color: Color = {
            switch proposal.confidence {
            case .high:      return .green
            case .medium:    return .orange
            case .uncertain: return .red
            case .unmatched: return .red
            }
        }()
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var rowBackground: Color {
        switch proposal.confidence {
        case .high:                                             return Color.clear
        case .medium:  return Color.orange.opacity(0.05)
        case .uncertain, .unmatched: return Color.red.opacity(0.05)
        }
    }

    private func syncStrings() {
        tnStr = proposal.proposedTrackNumber.map { "\($0)" } ?? ""
        tcStr = proposal.proposedTrackCount.map  { "\($0)" } ?? ""
        dnStr = proposal.proposedDiscNumber.map  { "\($0)" } ?? ""
        dcStr = proposal.proposedDiscCount.map   { "\($0)" } ?? ""
    }
}

// ── Artwork album (prima traccia) ──────────────────────────────────────────────

private struct AlbumArtwork: View {
    let pid: String
    let bridge: any AppleMusicBridge
    @State private var image: NSImage?
    @State private var zoom = false
    @State private var loadTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor))
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
        }
        .onAppear { load() }
        .onDisappear { loadTask?.cancel(); loadTask = nil }
        .onChange(of: pid) { _, _ in load() }
        .onTapGesture { if image != nil { zoom = true } }
        .help(image != nil ? "Clic per ingrandire" : "")
        .popover(isPresented: $zoom, arrowEdge: .trailing) {
            ArtworkZoomPopover(image: image)
        }
    }

    private func load() {
        loadTask?.cancel()
        image = nil
        guard !pid.isEmpty else { return }
        let p = pid
        loadTask = Task {
            let data = try? await bridge.artwork(persistentID: p)
            guard !Task.isCancelled else { return }
            await MainActor.run { if let d = data { image = NSImage(data: d) } }
        }
    }
}

// ── Popover copertina ingrandita (condiviso) ────────────────────────────────────

/// Mostra una copertina a dimensione maggiore in un popover.
/// Usato sia dalla Vista Album che dall'editor brano.
struct ArtworkZoomPopover: View {
    let image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            if let img = image {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(width: 400, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let rep = img.representations.first {
                    Text("\(rep.pixelsWide) × \(rep.pixelsHigh) px")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "music.note").font(.system(size: 48)).foregroundStyle(.tertiary)
                    .frame(width: 200, height: 200)
            }
        }
        .padding(12)
    }
}
