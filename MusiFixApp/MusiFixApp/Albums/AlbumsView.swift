import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    /// Testo di ricerca condiviso con la toolbar (filtra album per titolo/artista).
    var searchText: String = ""
    /// Chiave album su cui posizionarsi/selezionarsi all'apertura (da "Passa a vista album").
    var focusAlbumKey: String? = nil

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
    @State private var ignoredAlbumKeys: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var batchEditAlbums: [AlbumGroup]?
    /// Se impostato (da "Passa a vista album"), mostra solo quest'album invece dell'elenco generico.
    @State private var pinnedAlbumKey: String? = nil
    @State private var showUnplayedReport = false
    @State private var isRefreshingPlayCounts = false
    @State private var isExportingDiscography = false
    /// Nasconde i singoli / "non album" (meno di 5 tracce in libreria).
    @State private var hideNonAlbums = false

    /// Soglia minima di tracce per considerare un gruppo un vero "album".
    private static let albumMinTracks = 5

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
        if let key = pinnedAlbumKey {
            return albums.filter { $0.key == key }
        }
        let byCategory: [AlbumGroup]
        switch filter {
        case .all:        byCategory = albums
        case .incomplete: byCategory = albums.filter { $0.completeness == .incomplete }
        case .unknown:    byCategory = albums.filter { $0.completeness == .unknown }
        case .complete:   byCategory = albums.filter { $0.completeness == .complete }
        case .mixedCloud: byCategory = albums.filter { $0.hasMixedCloudStatus }
        }
        let byTracks = hideNonAlbums
            ? byCategory.filter { $0.actualCount >= Self.albumMinTracks }
            : byCategory
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return byTracks }
        return byTracks.filter {
            $0.album.localizedCaseInsensitiveContains(q) ||
            $0.albumArtist.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let key = pinnedAlbumKey, let album = albums.first(where: { $0.key == key }) {
                HStack {
                    Image(systemName: "pin.fill").foregroundStyle(.secondary)
                    Text("Vista filtrata sull'album \u{201C}\(album.album)\u{201D}")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Mostra tutti gli album") { pinnedAlbumKey = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            } else {
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { f in Text(f.label).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 420)
                    Toggle(isOn: $hideNonAlbums) {
                        Text("Solo album (≥ \(Self.albumMinTracks) tracce)")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Nasconde singoli e \u{201C}non album\u{201D} con meno di \(Self.albumMinTracks) tracce in libreria")
                    Spacer()
                    Text("\(filtered.count) album")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }

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
                    Divider().frame(height: 14)
                    Button("Modifica campi album… (\(selection.count))") { editSelectedAlbums() }
                        .font(.caption)
                        .disabled(selection.isEmpty)
                        .help("Modifica Album Artist, Anno e Genere su tutte le tracce degli album selezionati")
                    Divider().frame(height: 14)
                    if isRefreshingPlayCounts {
                        ProgressView().scaleEffect(0.6)
                        Text("Aggiornamento riproduzioni…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Aggiorna riproduzioni") { refreshPlayCounts() }
                            .font(.caption)
                            .disabled(appState.isIndexing)
                            .help("Rilegge da Music il numero di riproduzioni di ogni brano (l'ascolto non sempre aggiorna la sincronizzazione automatica)")
                    }
                    Button("Album mai riprodotti…") { showUnplayedReport = true }
                        .font(.caption)
                        .help("Elenca gli album le cui tracce non sono mai state (o quasi mai) riprodotte")
                    Divider().frame(height: 14)
                    if isExportingDiscography {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Button("Genera discografia…") { exportDiscography() }
                            .font(.caption)
                            .help("Genera discografica.md: per ogni artista con album completi, l'elenco degli album ordinati per anno")
                    }
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
                ScrollViewReader { proxy in
                List(filtered, selection: $selection) { album in
                    AlbumRow(album: album, store: storeInfo[album.key], bridge: appState.bridge,
                             isIgnored: ignoredAlbumKeys.contains(album.key))
                        .id(album.key)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpenTracks(album.album) }
                        .contextMenu {
                            Button("Apri brani per modifica") { onOpenTracks(album.album) }
                            Button("Modifica campi album (Album Artist, Anno, Genere)…") {
                                editAlbums(contextTarget: album)
                            }
                            Button("Allinea numeri traccia/disco…") { alignAlbum = album }
                            Button("Confronta durate (caricati)") { diffAlbum = album }
                                .disabled(storeInfo[album.key]?.collectionId == nil)
                            Divider()
                            if ignoredAlbumKeys.contains(album.key) {
                                Button("Non ignorare più in MusiFix") { setAlbumIgnore(album, ignore: false) }
                            } else {
                                Button("Ignora album in MusiFix") { setAlbumIgnore(album, ignore: true) }
                            }
                        }
                }
                .onChange(of: focusAlbumKey) { _, key in focus(key, proxy: proxy) }
                .onChange(of: isLoading) { _, loading in
                    if !loading { focus(focusAlbumKey, proxy: proxy) }
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
        .sheet(item: Binding(
            get: { batchEditAlbums.map { AlbumSelection(albums: $0) } },
            set: { batchEditAlbums = $0?.albums }
        )) { sel in
            AlbumBatchEditSheet(appState: appState, albums: sel.albums,
                                onClose: { batchEditAlbums = nil },
                                onApplied: { batchEditAlbums = nil; load() })
        }
        .sheet(isPresented: $showUnplayedReport) {
            UnplayedAlbumsReportView(appState: appState)
        }
    }

    /// Rilegge da Music il conteggio riproduzioni di tutti i brani (Fase 21):
    /// necessario perché l'ascolto non sempre aggiorna `modificationDate`, quindi
    /// il sync incrementale può non accorgersi che un brano è stato riprodotto.
    private func refreshPlayCounts() {
        isRefreshingPlayCounts = true
        Task {
            _ = try? await appState.indexService.refreshPlayCounts()
            await MainActor.run { isRefreshingPlayCounts = false }
        }
    }

    /// Genera `discografica.md`: per ogni artista con almeno un album completo,
    /// l'elenco dei suoi album completi ordinati per anno. Salva via NSSavePanel.
    private func exportDiscography() {
        isExportingDiscography = true
        Task {
            let artists = (try? await appState.albumService.discographyReport()) ?? []
            await MainActor.run {
                isExportingDiscography = false
                guard !artists.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "Nessun album completo"
                    alert.informativeText = "Non ci sono album verificati completi da includere nella discografia."
                    alert.runModal()
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = "discografica.md"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try Self.buildDiscographyMarkdown(artists).data(using: .utf8)?.write(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Impossibile salvare il file"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Un blocco per artista: nome come titolo, poi elenco puntato
    /// `- (anno) Album`. Anno mancante reso come `(?)`.
    private static func buildDiscographyMarkdown(_ artists: [AlbumService.DiscographyArtist]) -> String {
        var out = "# Discografia\n\n"
        for artist in artists {
            out += "## \(artist.artist)\n\n"
            for a in artist.albums {
                let year = a.year.map { "\($0)" } ?? "?"
                out += "- (\(year)) \(a.album)\n"
            }
            out += "\n"
        }
        return out
    }

    /// Filtra la vista sull'album indicato e lo seleziona (usato da "Passa a vista album").
    private func focus(_ key: String?, proxy: ScrollViewProxy) {
        guard let key, albums.contains(where: { $0.key == key }) else { return }
        pinnedAlbumKey = key
        selection = [key]
        withAnimation { proxy.scrollTo(key, anchor: .center) }
    }

    /// Apre lo sheet di editing per gli album attualmente selezionati.
    private func editSelectedAlbums() {
        let chosen = albums.filter { selection.contains($0.key) }
        guard !chosen.isEmpty else { return }
        batchEditAlbums = chosen
    }

    /// Apre lo sheet dal menu contestuale: usa la selezione se il target vi
    /// appartiene, altrimenti il solo album cliccato.
    private func editAlbums(contextTarget album: AlbumGroup) {
        if selection.contains(album.key) {
            batchEditAlbums = albums.filter { selection.contains($0.key) }
        } else {
            batchEditAlbums = [album]
        }
    }

    private func load() {
        isLoading = true; errorMessage = nil
        Task {
            do {
                let groups = try await appState.albumService.albumGroups()
                let store = try await appState.albumService.storeInfoByKey()
                let ignored = (try? await appState.ignoreService.ignoredAlbumKeys()) ?? []
                await MainActor.run {
                    albums = groups; storeInfo = store; ignoredAlbumKeys = ignored; isLoading = false
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isLoading = false }
            }
        }
    }

    private func setAlbumIgnore(_ album: AlbumGroup, ignore: Bool) {
        Task {
            if ignore {
                try? await appState.ignoreService.ignoreAlbum(
                    key: album.key, albumArtist: album.albumArtist, album: album.album)
            } else {
                try? await appState.ignoreService.unignoreAlbum(key: album.key)
            }
            ignoredAlbumKeys = (try? await appState.ignoreService.ignoredAlbumKeys()) ?? []
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
    var isIgnored: Bool = false

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

            if isIgnored {
                Label("Ignorato", systemImage: "nosign")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }
            countBadge
            completenessBadge
        }
        .padding(.vertical, 3)
        .opacity(isIgnored ? 0.55 : 1)
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

// ── Sheet editing massivo campi album (Fase 14) ────────────────────────────────

/// Wrapper Identifiable per pilotare `.sheet(item:)` con un insieme di album.
private struct AlbumSelection: Identifiable {
    let albums: [AlbumGroup]
    var id: String { albums.map { $0.key }.joined(separator: "\u{1f}") }
}

/// Modifica in blocco Album Artist / Anno / Genere su tutte le tracce di uno o più
/// album selezionati. Anteprima diff obbligatoria prima di scrivere.
private struct AlbumBatchEditSheet: View {
    let appState: AppState
    let albums: [AlbumGroup]
    var onClose: () -> Void
    var onApplied: () -> Void

    @State private var albumArtist = ""
    @State private var yearText = ""
    @State private var genre = ""

    @State private var overrideAlbumArtist = false
    @State private var overrideYear = false
    @State private var overrideGenre = false

    @State private var tracks: [DBTrack] = []
    @State private var genreSuggestions: [String] = []
    @State private var isLoading = true
    @State private var isWriting = false
    @State private var showDiff = false
    @State private var resultText: String?
    @State private var errorText: String?

    private var totalTracks: Int { albums.reduce(0) { $0 + $1.pids.count } }
    private var pids: [String] { albums.flatMap { $0.pids } }

    private var hasAnyOverride: Bool { overrideAlbumArtist || overrideYear || overrideGenre }

    private var yearInvalid: Bool {
        overrideYear && !yearText.isEmpty && Int(yearText) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modifica campi album").font(.headline)
                    Text("\(albums.count) album · \(totalTracks) brani")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Seleziona i campi da sovrascrivere su tutte le tracce degli album scelti.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    field("Album Artist", text: $albumArtist, enabled: $overrideAlbumArtist)
                    field("Anno", text: $yearText, enabled: $overrideYear, placeholder: "es. 1997")
                    if yearInvalid {
                        Text("Anno non valido (usa solo cifre, oppure lascia vuoto per azzerare).")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    genreField

                    if albums.count > 1 {
                        Text("Album interessati: " + albums.map { $0.album }.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    if let e = errorText {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button("Annulla") { onClose() }.keyboardShortcut(.cancelAction)
                if let r = resultText { Text(r).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isWriting { ProgressView().scaleEffect(0.6) }
                Button("Anteprima diff…") { showDiff = true }
                    .disabled(!hasAnyOverride || yearInvalid || isWriting || isLoading)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .overlay {
            if isLoading {
                ProgressView("Caricamento brani…")
                    .padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(isPresented: $showDiff) {
            DiffPreviewView(
                tracks: tracks,
                update: buildUpdate(),
                onConfirm: { showDiff = false; apply() },
                onCancel: { showDiff = false }
            )
        }
        .onAppear { load() }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, enabled: Binding<Bool>,
                       placeholder: String = "") -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabled).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(!enabled.wrappedValue)
                    .opacity(enabled.wrappedValue ? 1 : 0.5)
            }
        }
    }

    private var genreField: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $overrideGenre).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text("Genere").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", text: $genre)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .disabled(!overrideGenre)
                        .opacity(overrideGenre ? 1 : 0.5)
                    if !genreSuggestions.isEmpty {
                        Menu {
                            ForEach(genreSuggestions, id: \.self) { g in
                                Button(g) { genre = g; overrideGenre = true }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Scegli tra i generi esistenti")
                    }
                }
            }
        }
    }

    private func buildUpdate() -> TrackMetadataUpdate {
        var u = TrackMetadataUpdate()
        if overrideAlbumArtist { u.albumArtist = albumArtist }
        if overrideYear { u.year = Int(yearText) ?? 0 }
        if overrideGenre { u.genre = genre }
        return u
    }

    private func load() {
        isLoading = true
        let loadPids = pids
        Task {
            let loaded = (try? await appState.albumService.tracks(forPids: loadPids)) ?? []
            let genres = (try? await appState.albumService.distinctGenres()) ?? []
            await MainActor.run {
                tracks = loaded
                genreSuggestions = genres
                initFromCommonValues()
                isLoading = false
            }
        }
    }

    private func initFromCommonValues() {
        func common<T: Equatable>(_ kp: KeyPath<DBTrack, T>) -> T? {
            guard let first = tracks.first?[keyPath: kp] else { return nil }
            return tracks.dropFirst().allSatisfy { $0[keyPath: kp] == first } ? first : nil
        }
        if let v = common(\.albumArtist) { albumArtist = v }
        if albumArtist.isEmpty, let a = common(\.artist), !a.isEmpty {
            // Album Artist mancante: lo deduciamo dall'Artista comune.
            albumArtist = a
            overrideAlbumArtist = true
        }
        if let v = common(\.genre)       { genre = v }
        if let v = common(\.year), v > 0 { yearText = "\(v)" }
    }

    private func apply() {
        guard hasAnyOverride, !isWriting else { return }
        let update = buildUpdate()
        let writePids = pids
        isWriting = true; errorText = nil; resultText = nil
        Task {
            do {
                let r = try await appState.albumService.writeAlbumFields(pids: writePids, update: update)
                await MainActor.run {
                    isWriting = false
                    if r.failed.isEmpty {
                        onApplied()
                    } else {
                        resultText = "Aggiornate \(r.succeeded.count) tracce, \(r.failed.count) errori"
                    }
                }
            } catch {
                await MainActor.run {
                    isWriting = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// ── Sheet report album mai/quasi mai riprodotti (Fase 22) ──────────────────────

private struct UnplayedAlbumsReportView: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var maxTotalPlays = 0
    @State private var graceDays = 30
    @State private var albums: [AlbumService.UnplayedAlbum] = []
    @State private var isLoading = true

    private var zeroPlay: [AlbumService.UnplayedAlbum] { albums.filter { $0.kind == .zero } }
    private var partial: [AlbumService.UnplayedAlbum] { albums.filter { $0.kind == .partial } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Album mai riprodotti").font(.headline)
                Spacer()
                Button {
                    exportMarkdown()
                } label: {
                    Label("Esporta Markdown…", systemImage: "square.and.arrow.up")
                }
                .disabled(albums.isEmpty)
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            HStack(spacing: 16) {
                Text("Play totali \u{2264}").foregroundStyle(.secondary)
                stepperField(value: $maxTotalPlays, range: 0...50)
                Divider().frame(height: 18)
                Text("Escludi aggiunti negli ultimi").foregroundStyle(.secondary)
                stepperField(value: $graceDays, range: 0...365)
                Text("giorni").foregroundStyle(.secondary)
                Spacer()
                Text("\(albums.count) album").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: maxTotalPlays) { _, _ in load() }
            .onChange(of: graceDays) { _, _ in load() }
            Divider()

            if isLoading {
                Spacer(); ProgressView("Caricamento…"); Spacer()
            } else if albums.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Nessun album trovato con questi criteri").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !zeroPlay.isEmpty {
                        Section("Mai riprodotti (\(zeroPlay.count))") {
                            ForEach(zeroPlay) { row($0) }
                        }
                    }
                    if !partial.isEmpty {
                        Section("Parziali (\(partial.count))") {
                            ForEach(partial) { row($0) }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { load() }
    }

    private func row(_ a: AlbumService.UnplayedAlbum) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.album).lineLimit(1)
                Text(a.albumArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if a.kind == .partial, !a.playedTrackNames.isEmpty {
                    Text("Ascoltata: " + a.playedTrackNames.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            Text("\(a.trackCount) tracce").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(a.totalPlays) play")
                .font(.caption.monospacedDigit())
                .foregroundStyle(a.kind == .zero ? Color.secondary : Color.orange)
                .frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 12))
    }

    private func stepperField(value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Stepper("", value: value, in: range, step: 1).labelsHidden()
        }
    }

    private func load() {
        isLoading = true
        let maxPlays = maxTotalPlays, days = graceDays
        Task {
            let list = (try? await appState.albumService.unplayedAlbums(
                maxTotalPlays: maxPlays, graceDays: days)) ?? []
            await MainActor.run { albums = list; isLoading = false }
        }
    }

    /// Un titolo `##` per sezione (Mai riprodotti / Parziali), poi un elenco
    /// puntato `Artista — Album (N tracce · X play totali)`.
    private static func buildMarkdown(zero: [AlbumService.UnplayedAlbum], partial: [AlbumService.UnplayedAlbum]) -> String {
        func line(_ a: AlbumService.UnplayedAlbum) -> String {
            var s = "- \(a.albumArtist) — \(a.album) (\(a.trackCount) tracce · \(a.totalPlays) play totali)"
            if a.kind == .partial, !a.playedTrackNames.isEmpty {
                s += " — ascoltata: " + a.playedTrackNames.joined(separator: ", ")
            }
            return s
        }
        var out = ""
        if !zero.isEmpty {
            out += "## Mai riprodotti\n\n"
            for a in zero { out += line(a) + "\n" }
            out += "\n"
        }
        if !partial.isEmpty {
            out += "## Parziali\n\n"
            for a in partial { out += line(a) + "\n" }
            out += "\n"
        }
        return out
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "album-mai-riprodotti.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let md = Self.buildMarkdown(zero: zeroPlay, partial: partial)
        do {
            try md.data(using: .utf8)?.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossibile salvare il file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
