import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MusiFixCore
import Persistence

/// Vista Playlist (Fase 19): elenco delle playlist (con cartelle) a sinistra e
/// i brani contenuti a destra. Supporta selezione multipla per:
///  - esportare i brani delle playlist selezionate in un file Markdown;
///  - generare a video un report dei brani troppo corti / troppo lunghi.
/// Selezionare una cartella equivale a selezionare tutte le sue playlist figlie.
struct PlaylistsView: View {
    let appState: AppState
    /// (pids, nome playlist proposto come cartella) — copia i file dei brani.
    var onCopyFiles: ([String], String) -> Void
    var onScanRequested: () -> Void

    @State private var playlists: [DBPlaylist] = []
    @State private var selection: Set<String> = []
    @State private var tracks: [DBTrack] = []
    @State private var scanDone = true
    @State private var showDurationReport = false
    @State private var showAnalysis = false
    @State private var showAdvancedAnalysis = false
    @State private var showReorganize = false

    /// Playlist effettivamente coinvolte dalla selezione: le cartelle selezionate
    /// vengono espanse nelle loro figlie; risultato de-duplicato e ordinato.
    private var effectivePlaylists: [DBPlaylist] {
        var seen = Set<String>()
        var result: [DBPlaylist] = []
        for id in selection {
            guard let pl = playlists.first(where: { $0.id == id }) else { continue }
            let targets = pl.isFolder ? children(of: pl.id) : [pl]
            for t in targets where !seen.contains(t.id) {
                seen.insert(t.id)
                result.append(t)
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var singlePlaylist: DBPlaylist? {
        effectivePlaylists.count == 1 ? effectivePlaylists.first : nil
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
        .sheet(isPresented: $showDurationReport) {
            DurationReportView(groups: groupedTracks())
        }
        .sheet(isPresented: $showAnalysis) {
            if let pl = singlePlaylist {
                PlaylistAnalysisSheet(appState: appState, playlistID: pl.id, playlistName: pl.name)
            }
        }
        .sheet(isPresented: $showAdvancedAnalysis) {
            if let pl = singlePlaylist {
                AdvancedAnalysisSheet(
                    appState: appState, playlistID: pl.id, playlistName: pl.name, currentTracks: tracks)
            }
        }
        .sheet(isPresented: $showReorganize) {
            ReorganizeSheet(
                appState: appState,
                playlists: effectivePlaylists.map { PlaylistRef(id: $0.id, name: $0.name) })
        }
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
        List(selection: $selection) {
            let top = children(of: nil)
            if !top.isEmpty {
                Section("Playlist") {
                    ForEach(top) { playlistRow($0) }
                }
            }
            ForEach(folders) { folder in
                let kids = children(of: folder.id)
                if !kids.isEmpty {
                    Section {
                        folderRow(folder)
                        ForEach(kids) { playlistRow($0).padding(.leading, 14) }
                    }
                }
            }
        }
        .onChange(of: selection) { _, _ in loadPreview() }
    }

    private func playlistRow(_ pl: DBPlaylist) -> some View {
        HStack {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            Text(pl.name).lineLimit(1)
        }
        .tag(pl.id)
    }

    private func folderRow(_ folder: DBPlaylist) -> some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(folder.name).fontWeight(.medium).lineLimit(1)
        }
        .tag(folder.id)
        .help("Seleziona tutte le playlist della cartella")
    }

    // ── Dettaglio ────────────────────────────────────────────────────────────────

    private var detail: some View {
        VStack(spacing: 0) {
            if effectivePlaylists.isEmpty {
                placeholder
            } else {
                header
                Divider()
                if singlePlaylist != nil {
                    trackPreview
                } else {
                    multiSummary
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if let pl = singlePlaylist {
                Text(pl.name).font(.headline).lineLimit(1)
                Text("\(tracks.count) brani").font(.caption).foregroundStyle(.secondary)
            } else {
                let count = effectivePlaylists.count
                Text("\(count) playlist selezionate").font(.headline)
                Text("\(totalTrackCount) brani").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showDurationReport = true
            } label: {
                Label("Report durate…", systemImage: "clock")
            }
            .help("Elenca a video i brani più corti o più lunghi delle soglie indicate")
            Button {
                exportMarkdown()
            } label: {
                Label("Esporta Markdown…", systemImage: "square.and.arrow.up")
            }
            .help("Salva un file .md con le playlist selezionate e i brani contenuti")
            if singlePlaylist == nil && effectivePlaylists.count >= 2 {
                Button {
                    showReorganize = true
                } label: {
                    Label("Riorganizza (AI)…", systemImage: "arrow.left.arrow.right")
                }
                .help("Sposta brani tra le playlist selezionate secondo un criterio logico, tramite AI cloud")
            }
            if let pl = singlePlaylist {
                Button {
                    onCopyFiles(tracks.map(\.persistentID), pl.name)
                } label: {
                    Label("Copia file…", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(tracks.allSatisfy { $0.locationPath == nil })
                .help("Copia i file locali dei brani in una sottocartella col nome della playlist")
                Button {
                    showAnalysis = true
                } label: {
                    Label("Analizza playlist…", systemImage: "sparkles")
                }
                .disabled(tracks.isEmpty)
                .help("Analizza sequenza, artisti e generi della playlist (metadati + euristiche, Apple Intelligence se disponibile)")
                Button {
                    showAdvancedAnalysis = true
                } label: {
                    Label("Analisi avanzata (AI)…", systemImage: "wand.and.stars")
                }
                .disabled(tracks.isEmpty)
                .help("Suggerisce integrazioni dalla libreria e un ordinamento tramite AI cloud (Claude/OpenAI)")
            }
        }
        .padding(10)
    }

    private var trackPreview: some View {
        VStack(spacing: 0) {
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
        }
    }

    private var multiSummary: some View {
        List(effectivePlaylists) { pl in
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(.secondary)
                Text(pl.name).lineLimit(1)
                Spacer()
                Text("\(playlistCount(pl.id)) brani").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Seleziona una o più playlist").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // ── Conteggi ─────────────────────────────────────────────────────────────────

    private func playlistCount(_ id: String) -> Int {
        (try? appState.db.read { try PlaylistDAO.trackCount(id: id, in: $0) }) ?? 0
    }

    private var totalTrackCount: Int {
        effectivePlaylists.reduce(0) { $0 + playlistCount($1.id) }
    }

    // ── Caricamento ──────────────────────────────────────────────────────────────

    func reload() {
        scanDone = (try? appState.db.read { try PlaylistDAO.scanDone(in: $0) }) ?? false
        playlists = (try? appState.db.read { try PlaylistDAO.fetchPlaylists(in: $0) }) ?? []
        selection = selection.filter { id in playlists.contains { $0.id == id } }
        if selection.isEmpty, let first = children(of: nil).first?.id
            ?? folders.compactMap({ children(of: $0.id).first?.id }).first {
            selection = [first]
        }
        loadPreview()
    }

    /// Carica l'anteprima brani solo quando è selezionata una singola playlist.
    private func loadPreview() {
        guard let pl = singlePlaylist else { tracks = []; return }
        tracks = (try? appState.db.read { try PlaylistDAO.tracksInPlaylist(id: pl.id, in: $0) }) ?? []
    }

    /// Brani di ciascuna playlist effettiva, per export e report.
    private func groupedTracks() -> [PlaylistGroup] {
        effectivePlaylists.map { pl in
            let ts = (try? appState.db.read { try PlaylistDAO.tracksInPlaylist(id: pl.id, in: $0) }) ?? []
            return PlaylistGroup(name: pl.name, tracks: ts)
        }
    }

    // ── Export Markdown ──────────────────────────────────────────────────────────

    private func exportMarkdown() {
        let groups = groupedTracks()
        guard !groups.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = groups.count == 1 ? "\(safeFileName(groups[0].name)).md" : "playlist.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let md = Self.buildMarkdown(groups)
        do {
            try md.data(using: .utf8)?.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossibile salvare il file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    /// Un titolo `##` per playlist, poi un elenco puntato `Titolo — Artista — Anno — Genere`
    /// omettendo i campi mancanti (anno 0, artista/genere vuoti).
    static func buildMarkdown(_ groups: [PlaylistGroup]) -> String {
        var out = ""
        for group in groups {
            out += "## \(group.name)\n\n"
            for t in group.tracks {
                var parts: [String] = [t.name.isEmpty ? "(senza titolo)" : t.name]
                if !t.artist.isEmpty { parts.append(t.artist) }
                if t.year > 0 { parts.append(String(t.year)) }
                if !t.genre.isEmpty { parts.append(t.genre) }
                out += "- " + parts.joined(separator: " — ") + "\n"
            }
            out += "\n"
        }
        return out
    }
}

/// Playlist con i suoi brani, unità di lavoro per export e report.
struct PlaylistGroup: Identifiable {
    let name: String
    let tracks: [DBTrack]
    var id: String { name }
}

/// Report a video delle playlist la cui durata totale è fuori dal range [shortMin, longMin] (in minuti interi).
private struct DurationReportView: View {
    let groups: [PlaylistGroup]

    @Environment(\.dismiss) private var dismiss
    @State private var checkShort = true
    @State private var shortMin = 60
    @State private var checkLong = true
    @State private var longMin = 120

    private struct Finding: Identifiable {
        let id = UUID()
        let playlist: String
        let tracks: [DBTrack]
        let totalSeconds: Double
        let tooShort: Bool
        var offByMinutes: Int {
            let totalMinutes = totalSeconds / 60
            return tooShort
                ? Int((Double(shortMinAtCreation) - totalMinutes).rounded(.up))
                : Int((totalMinutes - Double(longMinAtCreation)).rounded(.up))
        }
        let shortMinAtCreation: Int
        let longMinAtCreation: Int
    }

    private var findings: [Finding] {
        var result: [Finding] = []
        for group in groups {
            let totalSeconds = group.tracks.reduce(0.0) { $0 + $1.duration }
            let totalMinutes = totalSeconds / 60
            let sortedTracks = group.tracks.sorted { $0.duration < $1.duration }
            if checkShort && totalMinutes < Double(shortMin) {
                result.append(Finding(playlist: group.name, tracks: sortedTracks, totalSeconds: totalSeconds, tooShort: true, shortMinAtCreation: shortMin, longMinAtCreation: longMin))
            } else if checkLong && totalMinutes > Double(longMin) {
                result.append(Finding(playlist: group.name, tracks: sortedTracks, totalSeconds: totalSeconds, tooShort: false, shortMinAtCreation: shortMin, longMinAtCreation: longMin))
            }
        }
        return result.sorted { $0.playlist.localizedCaseInsensitiveCompare($1.playlist) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Report durate").font(.headline)
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            HStack(spacing: 16) {
                Toggle(isOn: $checkShort) { Text("Playlist più corte di") }
                stepperField(value: $shortMin).disabled(!checkShort)
                Text("min").foregroundStyle(.secondary)
                Divider().frame(height: 18)
                Toggle(isOn: $checkLong) { Text("Playlist più lunghe di") }
                stepperField(value: $longMin).disabled(!checkLong)
                Text("min").foregroundStyle(.secondary)
                Spacer()
                Text("\(findings.count) playlist").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if findings.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Nessuna playlist fuori range").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(findings) { f in
                        Section {
                            ForEach(f.tracks, id: \.persistentID) { t in
                                HStack(spacing: 8) {
                                    Text(t.name.isEmpty ? "(senza titolo)" : t.name).lineLimit(1)
                                    Text(t.artist).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(Self.formatDuration(t.duration))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: f.tooShort ? "arrow.down.right.circle" : "arrow.up.right.circle")
                                    .foregroundStyle(f.tooShort ? .orange : .blue)
                                Text(f.playlist)
                                Spacer()
                                Text(Self.formatDuration(f.totalSeconds))
                                    .font(.system(.body, design: .monospaced))
                                Text(f.tooShort ? "(-\(f.offByMinutes) min sotto soglia)" : "(+\(f.offByMinutes) min oltre soglia)")
                                    .foregroundStyle(f.tooShort ? .orange : .blue)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func stepperField(value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Stepper("", value: value, in: 0...600, step: 1).labelsHidden()
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Sheet di analisi playlist (Fase 23): sceglie l'obiettivo, mostra i punteggi
/// euristici (sempre calcolati) e, se disponibile, la narrativa Apple Intelligence.
private struct PlaylistAnalysisSheet: View {
    let appState: AppState
    let playlistID: String
    let playlistName: String

    @Environment(\.dismiss) private var dismiss
    @State private var goal: PlaylistGoal = .balanced
    @State private var analysis: PlaylistAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var descriptionText = ""
    @State private var desiredResultText = ""
    @State private var annotationLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analizza playlist").font(.headline)
                    Text(playlistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let analysis {
                    Button {
                        exportMarkdown(analysis)
                    } label: {
                        Label("Esporta Markdown…", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            HStack(spacing: 12) {
                Text("Obiettivo desiderato").foregroundStyle(.secondary)
                Picker("", selection: $goal) {
                    ForEach(PlaylistGoal.allCases) { g in Text(g.label).tag(g) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.6) }
                Button(analysis == nil ? "Analizza" : "Rianalizza") { runAnalysis() }
                    .disabled(isLoading)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: goal) { _, _ in if analysis != nil { runAnalysis() } }

            annotationEditor
            Divider()

            if let err = errorMessage {
                Spacer(); Text(err).foregroundStyle(.red).padding(); Spacer()
            } else if let analysis {
                ScrollView { analysisContent(analysis) }
            } else if isLoading {
                Spacer(); ProgressView("Analisi in corso…"); Spacer()
            } else {
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Scegli l'obiettivo e premi Analizza.").foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            }
        }
        .frame(width: 560, height: 620)
        .onAppear { loadAnnotation(); runAnalysis() }
    }

    /// Editor della descrizione e del risultato desiderato, persistiti per playlist
    /// e usati per guidare il verdetto dell'analisi.
    private var annotationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Descrizione").font(.caption).foregroundStyle(.secondary)
                    TextField("A cosa serve questa playlist…", text: $descriptionText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Risultato desiderato").font(.caption).foregroundStyle(.secondary)
                    TextField("Com'è la playlist ideale…", text: $desiredResultText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    @ViewBuilder
    private func analysisContent(_ a: PlaylistAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                scoreGauge("Coerenza", a.scores.coherence, .blue)
                scoreGauge("Varietà", a.scores.variety, .green)
                scoreGauge("Bilanciamento", a.scores.balance, .orange)
            }

            if let narrative = a.narrative {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Apple Intelligence", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(.purple)
                    Text(narrative.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    ForEach(narrative.suggestions, id: \.self) { s in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(s).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(10)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let reason = a.intelligenceUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }

            artistsSection(a.features)
            genresSection(a.features)
            durationsSection(a.features)
        }
        .padding(16)
    }

    private func scoreGauge(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(value) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(value)").font(.system(size: 14, weight: .bold))
            }
            .frame(width: 56, height: 56)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func artistsSection(_ f: PlaylistFeatures) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Artisti (\(f.distinctArtistCount) distinti, inclusi featuring)")
                .font(.caption.bold()).foregroundStyle(.secondary)
            if f.maxConsecutiveRepeats > 1 {
                Text("Fino a \(f.maxConsecutiveRepeats) brani consecutivi dello stesso artista.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach(f.topArtists, id: \.name) { stat in
                HStack {
                    Text(stat.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(stat.count) · \(Int(stat.percentage))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func genresSection(_ f: PlaylistFeatures) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Generi (diversità \(Int(f.genreDiversityIndex * 100))%)")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(f.genreDistribution.prefix(5), id: \.name) { stat in
                HStack {
                    Text(stat.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(stat.count) · \(Int(stat.percentage))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func durationsSection(_ f: PlaylistFeatures) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Durate").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Text("Media \(DurationReportView.formatDuration(f.averageDuration))")
                Spacer()
                if let range = f.yearRange {
                    Text("Anni \(range.lowerBound)–\(range.upperBound) (\(f.distinctDecadesCount) decadi)")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Carica l'annotazione salvata (descrizione + risultato desiderato) una sola volta.
    private func loadAnnotation() {
        guard !annotationLoaded else { return }
        annotationLoaded = true
        if let ann = try? appState.db.read({ try PlaylistDAO.annotation(playlistID: playlistID, in: $0) }) {
            descriptionText = ann.playlistDescription
            desiredResultText = ann.desiredResult
        }
    }

    /// Persiste descrizione e risultato desiderato prima di ogni analisi.
    private func saveAnnotation() {
        let pid = playlistID, desc = descriptionText, desired = desiredResultText
        try? appState.db.write { db in
            try PlaylistDAO.upsertAnnotation(
                playlistID: pid, description: desc, desiredResult: desired, in: db)
        }
    }

    private func runAnalysis() {
        saveAnnotation()
        isLoading = true; errorMessage = nil
        let pid = playlistID, name = playlistName, g = goal
        Task {
            do {
                let result = try await appState.playlistAnalysisService.analyze(
                    playlistID: pid, playlistName: name, goal: g)
                await MainActor.run { analysis = result; isLoading = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isLoading = false }
            }
        }
    }

    private func exportMarkdown(_ a: PlaylistAnalysis) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(playlistName)-analisi.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let md = Self.buildMarkdown(playlistName: playlistName, goal: goal, analysis: a)
        do {
            try md.data(using: .utf8)?.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossibile salvare il file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func buildMarkdown(playlistName: String, goal: PlaylistGoal, analysis a: PlaylistAnalysis) -> String {
        var out = "## \(playlistName)\n\n"
        out += "Obiettivo: \(goal.label)\n\n"
        out += "- Coerenza: \(a.scores.coherence)/100\n"
        out += "- Varietà: \(a.scores.variety)/100\n"
        out += "- Bilanciamento: \(a.scores.balance)/100\n\n"
        if let n = a.narrative {
            out += n.text + "\n\n"
            for s in n.suggestions { out += "- \(s)\n" }
            out += "\n"
        }
        out += "### Artisti principali\n\n"
        for stat in a.features.topArtists { out += "- \(stat.name): \(stat.count) (\(Int(stat.percentage))%)\n" }
        out += "\n### Generi\n\n"
        for stat in a.features.genreDistribution.prefix(5) { out += "- \(stat.name): \(stat.count) (\(Int(stat.percentage))%)\n" }
        return out
    }
}

// MARK: - Analisi avanzata (AI cloud)

/// Sheet di analisi avanzata (Fase 2 evolutiva): usa un LLM cloud per suggerire
/// integrazioni dalla libreria (confermate una a una prima dell'aggiunta a Music)
/// e, sull'insieme finale, un ordinamento mostrato solo a video.
private struct AdvancedAnalysisSheet: View {
    let appState: AppState
    let playlistID: String
    let playlistName: String
    let currentTracks: [DBTrack]

    @Environment(\.dismiss) private var dismiss
    @State private var configured: Bool?
    @State private var showConfig = false

    @State private var loadingAdditions = false
    @State private var verdict: String?
    @State private var additions: [SuggestedAddition] = []
    @State private var addedIDs: Set<String> = []
    @State private var addedTracks: [DBTrack] = []
    @State private var addingID: String?

    @State private var loadingOrder = false
    @State private var order: OrderSuggestion?

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 680)
        .onAppear { refreshConfigured() }
        .sheet(isPresented: $showConfig, onDismiss: { refreshConfigured() }) {
            LLMConfigSheet()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analisi avanzata (AI)").font(.headline)
                Text(playlistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                showConfig = true
            } label: { Label("Configura AI…", systemImage: "gearshape") }
            Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch configured {
        case .none:
            Spacer(); ProgressView(); Spacer()
        case .some(false):
            notConfiguredState
        case .some(true):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let err = errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    }
                    additionsSection
                    if !addedTracks.isEmpty || !additions.isEmpty { Divider() }
                    orderSection
                }
                .padding(16)
            }
        }
    }

    private var notConfiguredState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Nessun provider AI configurato.").foregroundStyle(.secondary)
            Text("Imposta provider (Claude o OpenAI), modello e chiave API.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Configura AI…") { showConfig = true }.buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Integrazioni ─────────────────────────────────────────────────────────

    private var additionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Integrazioni suggerite", systemImage: "plus.circle").font(.headline)
                Spacer()
                if loadingAdditions { ProgressView().scaleEffect(0.6) }
                Button(verdict == nil ? "Suggerisci integrazioni" : "Rigenera") { runAdditions() }
                    .disabled(loadingAdditions)
                    .buttonStyle(.borderedProminent)
            }
            if let verdict, !verdict.isEmpty {
                Text(verdict).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if verdict != nil && additions.isEmpty && !loadingAdditions {
                Text("Nessuna integrazione proposta.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(additions) { item in additionRow(item) }
        }
    }

    private func additionRow(_ item: SuggestedAddition) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.name.isEmpty ? "(senza titolo)" : item.track.name)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(item.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !item.reason.isEmpty {
                    Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if addedIDs.contains(item.id) {
                Label("Aggiunto", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else if addingID == item.id {
                ProgressView().scaleEffect(0.6)
            } else {
                Button("Aggiungi") { addOne(item) }.controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // ── Ordine ───────────────────────────────────────────────────────────────

    private var orderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Ordinamento suggerito", systemImage: "list.number").font(.headline)
                Spacer()
                if loadingOrder { ProgressView().scaleEffect(0.6) }
                Button(order == nil ? "Suggerisci ordine" : "Ricalcola ordine") { runOrder() }
                    .disabled(loadingOrder)
            }
            Text("Calcolato sull'insieme finale (brani attuali + integrazioni confermate). Solo a video.")
                .font(.caption2).foregroundStyle(.secondary)
            if let order {
                if !order.rationale.isEmpty {
                    Text(order.rationale).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(order.orderedTracks.enumerated()), id: \.offset) { idx, t in
                    HStack(spacing: 8) {
                        Text("\(idx + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(t.name.isEmpty ? "(senza titolo)" : t.name).font(.system(size: 12)).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if addedIDs.contains(t.persistentID) {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.caption2)
                        }
                    }
                }
            }
        }
    }

    // ── Azioni ───────────────────────────────────────────────────────────────

    private func refreshConfigured() {
        Task {
            let ok = await appState.advancedPlaylistAnalysisService.isConfigured
            await MainActor.run { configured = ok }
        }
    }

    private func runAdditions() {
        loadingAdditions = true; errorMessage = nil
        let pid = playlistID, name = playlistName
        Task {
            do {
                let result = try await appState.advancedPlaylistAnalysisService
                    .suggestAdditions(playlistID: pid, playlistName: name)
                await MainActor.run {
                    verdict = result.verdict
                    additions = result.additions
                    loadingAdditions = false
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; loadingAdditions = false }
            }
        }
    }

    private func addOne(_ item: SuggestedAddition) {
        addingID = item.id; errorMessage = nil
        let pid = playlistID, track = item.track
        Task {
            do {
                _ = try await appState.bridge.addTracks([track.persistentID], toPlaylistID: pid)
                await MainActor.run {
                    addedIDs.insert(track.persistentID)
                    addedTracks.append(track)
                    addingID = nil
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; addingID = nil }
            }
        }
    }

    private func runOrder() {
        loadingOrder = true; errorMessage = nil
        // Insieme finale: brani attuali + integrazioni confermate (dedup per persistentID).
        var seen = Set(currentTracks.map(\.persistentID))
        var finalTracks = currentTracks
        for t in addedTracks where !seen.contains(t.persistentID) {
            seen.insert(t.persistentID); finalTracks.append(t)
        }
        let pid = playlistID, name = playlistName, tracks = finalTracks
        Task {
            do {
                let result = try await appState.advancedPlaylistAnalysisService
                    .suggestOrder(playlistID: pid, playlistName: name, finalTracks: tracks)
                await MainActor.run { order = result; loadingOrder = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; loadingOrder = false }
            }
        }
    }
}

/// Configurazione del provider AI cloud: provider, modello, endpoint (opzionale)
/// e chiave API (salvata nel Keychain).
private struct LLMConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: LLMProvider = LLMConfigStore.provider
    @State private var model = ""
    @State private var endpoint = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Configura AI").font(.headline)
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(LLMProvider.allCases) { p in Text(p.label).tag(p) }
                }
                .onChange(of: provider) { _, newValue in loadForProvider(newValue) }

                TextField("Modello", text: $model, prompt: Text(provider.defaultModel))
                SecureField("Chiave API", text: $apiKey)
                TextField("Endpoint (opzionale)", text: $endpoint, prompt: Text(provider.defaultEndpoint))
                    .font(.system(size: 11, design: .monospaced))
            }
            .padding(12)

            Text("La chiave API viene salvata nel Keychain di macOS. I metadati dei brani (titoli, artisti, generi) vengono inviati al provider selezionato durante l'analisi.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            Spacer()
            HStack {
                Spacer()
                Button("Salva") { save() }.buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 360)
        .onAppear { loadForProvider(provider) }
    }

    private func loadForProvider(_ p: LLMProvider) {
        apiKey = LLMConfigStore.apiKey(for: p)
        // Modello/endpoint sono condivisi: se vuoti mostrano il default via prompt.
        if model.isEmpty { model = LLMConfigStore.model }
        if endpoint.isEmpty { endpoint = LLMConfigStore.endpoint }
    }

    private func save() {
        LLMConfigStore.provider = provider
        LLMConfigStore.model = model.trimmingCharacters(in: .whitespaces)
        LLMConfigStore.endpoint = endpoint.trimmingCharacters(in: .whitespaces)
        LLMConfigStore.setAPIKey(apiKey.trimmingCharacters(in: .whitespaces), for: provider)
        dismiss()
    }
}

// MARK: - Riorganizzazione multi-playlist (AI cloud)

/// Sheet di riorganizzazione (punto 6): dato un criterio logico, l'AI propone di
/// spostare brani tra le playlist selezionate. Ogni spostamento è confermato uno a
/// uno (aggiunta su destinazione + rimozione da origine, via bridge Music.app).
private struct ReorganizeSheet: View {
    let appState: AppState
    let playlists: [PlaylistRef]

    @Environment(\.dismiss) private var dismiss
    @State private var configured: Bool?
    @State private var showConfig = false
    @State private var criterion = ""
    @State private var loading = false
    @State private var summary: String?
    @State private var moves: [SuggestedMove] = []
    @State private var appliedIDs: Set<String> = []
    @State private var applyingID: String?
    @State private var errorMessage: String?
    /// Se true lo spostamento rimuove il brano dall'origine; se false lo copia soltanto.
    @State private var removeFromSource = true
    @State private var pendingMove: SuggestedMove?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Riorganizza playlist (AI)").font(.headline)
                    Text("\(playlists.count) playlist selezionate")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showConfig = true } label: { Label("Configura AI…", systemImage: "gearshape") }
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(width: 640, height: 700)
        .onAppear { refreshConfigured() }
        .sheet(isPresented: $showConfig, onDismiss: { refreshConfigured() }) { LLMConfigSheet() }
        .alert("Confermi l'operazione?",
               isPresented: Binding(get: { pendingMove != nil },
                                    set: { if !$0 { pendingMove = nil } }),
               presenting: pendingMove) { m in
            Button(removeFromSource ? "Sposta" : "Copia", role: .destructive) {
                apply(m); pendingMove = nil
            }
            Button("Annulla", role: .cancel) { pendingMove = nil }
        } message: { m in
            let title = m.track.name.isEmpty ? "(senza titolo)" : m.track.name
            Text(removeFromSource
                 ? "«\(title)» verrà aggiunto a «\(m.toName)» e rimosso da «\(m.fromName)»."
                 : "«\(title)» verrà aggiunto a «\(m.toName)» e resterà anche in «\(m.fromName)».")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch configured {
        case .none:
            Spacer(); ProgressView(); Spacer()
        case .some(false):
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wand.and.stars").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Nessun provider AI configurato.").foregroundStyle(.secondary)
                Button("Configura AI…") { showConfig = true }.buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(true):
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Criterio logico di composizione").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Es. separa per decennio, o raggruppa i brani energici…",
                                  text: $criterion, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                        if loading { ProgressView().scaleEffect(0.6) }
                        Button(summary == nil ? "Analizza" : "Rigenera") { run() }
                            .disabled(loading || criterion.trimmingCharacters(in: .whitespaces).isEmpty)
                            .buttonStyle(.borderedProminent)
                    }
                    Toggle("Rimuovi dalla playlist di origine (sposta invece di copiare)",
                           isOn: $removeFromSource)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                Divider()
                resultsList
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                }
                if let summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if summary != nil && moves.isEmpty && !loading {
                    Text("Nessuno spostamento proposto.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(moves) { moveRow($0) }
            }
            .padding(16)
        }
    }

    private func moveRow(_ m: SuggestedMove) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.track.name.isEmpty ? "(senza titolo)" : m.track.name)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(m.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(m.fromName).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9))
                    Text(m.toName).foregroundStyle(.blue)
                }
                .font(.caption2)
                if !m.reason.isEmpty {
                    Text(m.reason).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if appliedIDs.contains(m.id) {
                Label("Fatto", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else if applyingID == m.id {
                ProgressView().scaleEffect(0.6)
            } else {
                Button(removeFromSource ? "Sposta" : "Copia") { pendingMove = m }.controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // ── Azioni ───────────────────────────────────────────────────────────────

    private func refreshConfigured() {
        Task {
            let ok = await appState.advancedPlaylistAnalysisService.isConfigured
            await MainActor.run { configured = ok }
        }
    }

    private func run() {
        loading = true; errorMessage = nil; summary = nil; moves = []
        let pls = playlists, crit = criterion
        Task {
            do {
                let result = try await appState.advancedPlaylistAnalysisService
                    .suggestReorganization(playlists: pls, criterion: crit)
                await MainActor.run { summary = result.summary; moves = result.moves; loading = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; loading = false }
            }
        }
    }

    /// Applica l'operazione: aggiunge alla destinazione e, se richiesto, rimuove
    /// dall'origine. L'aggiunta precede la rimozione così il brano non sparisce mai
    /// se l'aggiunta fallisse.
    private func apply(_ m: SuggestedMove) {
        applyingID = m.id; errorMessage = nil
        let pid = m.track.persistentID, fromID = m.fromID, toID = m.toID
        let remove = removeFromSource
        Task {
            do {
                _ = try await appState.bridge.addTracks([pid], toPlaylistID: toID)
                if remove {
                    _ = try await appState.bridge.removeTracks([pid], fromPlaylistID: fromID)
                }
                await MainActor.run { appliedIDs.insert(m.id); applyingID = nil }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; applyingID = nil }
            }
        }
    }
}
