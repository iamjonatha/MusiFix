import SwiftUI
import AppKit
import MusiFixCore

/// Sheet per la ricerca dei file audio orfani nella cartella media di Music:
/// file presenti sul disco ma non referenziati da alcuna traccia della libreria.
/// Consente lo spostamento nel Cestino in sicurezza (preselezione dei soli "sicuri").
struct OrphansView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var hasScanned = false
    @State private var isScanning = false
    @State private var scanned = 0
    @State private var foundSoFar = 0

    @State private var orphans: [OrphanFile] = []
    @State private var totalScanned = 0
    @State private var referencedCount = 0
    @State private var mediaFolder = ""

    @State private var selection: Set<String> = []
    @State private var isTrashing = false
    @State private var errorMessage: String? = nil
    @State private var lastFreed: Int64? = nil

    @State private var showTrashConfirm = false
    @State private var showTrashConfirm2 = false

    private var confidentOrphans: [OrphanFile] { orphans.filter { $0.confidence.isConfident } }
    private var possibleOrphans: [OrphanFile]  { orphans.filter { !$0.confidence.isConfident } }
    private var selectedFiles: [OrphanFile]    { orphans.filter { selection.contains($0.path) } }
    private var selectedBytes: Int64           { selectedFiles.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 780, height: 600)
        .confirmationDialog(
            "Spostare \(selection.count) file nel Cestino?",
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            if selection.count > DeletionService.doubleConfirmThreshold {
                Button("Continua…", role: .destructive) { showTrashConfirm2 = true }
            } else {
                Button("Sposta nel Cestino", role: .destructive) { Task { await runTrash() } }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno spostati \(selection.count) file (\(byteString(selectedBytes))) nel Cestino macOS. L'operazione è reversibile dal Cestino finché non lo svuoti.")
        }
        .confirmationDialog(
            "Confermi lo spostamento di \(selection.count) file?",
            isPresented: $showTrashConfirm2,
            titleVisibility: .visible
        ) {
            Button("Sposta \(selection.count) file nel Cestino", role: .destructive) { Task { await runTrash() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Stai per spostare un numero elevato di file (\(byteString(selectedBytes))). Controlla la selezione, soprattutto nella sezione \u{201C}Dubbi\u{201D}.")
        }
    }

    // ── Header ─────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("File orfani su disco").font(.headline)
                Text("File audio nella cartella media non più presenti nella libreria Music")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(16)
    }

    // ── Contenuto ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Scansionati \(scanned) file · \(foundSoFar) orfani")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if !hasScanned {
            introView
        } else if orphans.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(.green)
                Text("Nessun file orfano trovato.").foregroundStyle(.secondary)
                Text("\(totalScanned) file scansionati · \(referencedCount) referenziati dalla libreria")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            resultsView
        }
    }

    private var introView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Trova i file audio rimasti sul disco")
                .font(.title3.bold())
            Text("Confronta i file della cartella media di Music con le tracce della libreria e individua quelli non più referenziati (es. brani eliminati solo da Music, import incompleti).")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scansiona file orfani") { Task { await runScan() } }
                .buttonStyle(.borderedProminent)
            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Riepilogo
            HStack(spacing: 10) {
                summaryChip("\(orphans.count)", "orfani", .primary)
                summaryChip("\(confidentOrphans.count)", "sicuri", .green)
                summaryChip("\(possibleOrphans.count)", "dubbi", .orange)
                Spacer()
                Text("\(byteString(orphans.reduce(0) { $0 + $1.sizeBytes })) liberabili")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await runScan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Ripeti la scansione")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if !mediaFolder.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.caption2).foregroundStyle(.tertiary)
                    Text(mediaFolder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }

            Divider()

            List {
                if !confidentOrphans.isEmpty {
                    Section("Sicuri — nessuna corrispondenza in libreria") {
                        ForEach(confidentOrphans) { row($0) }
                    }
                }
                if !possibleOrphans.isEmpty {
                    Section("Dubbi — titolo presente in libreria (rivedere)") {
                        ForEach(possibleOrphans) { row($0) }
                    }
                }
            }
        }
    }

    private func summaryChip(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // ── Riga file ──────────────────────────────────────────────────────────────

    private func row(_ f: OrphanFile) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(f.path) },
                set: { on in if on { selection.insert(f.path) } else { selection.remove(f.path) } }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(f.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(folderLabel(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    badge(f.format.uppercased(), .blue)
                    Text(byteString(f.sizeBytes)).font(.caption2).foregroundStyle(.tertiary)
                    if let d = f.modDate {
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if case .possibleMatch(let track, let artist) = f.confidence {
                        Text("· possibile: \(track)\(artist.isEmpty ? "" : " — \(artist)")")
                            .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
            }

            Spacer()

            confidenceBadge(f.confidence)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Mostra nel Finder")
        }
        .padding(.vertical, 2)
    }

    private func folderLabel(_ f: OrphanFile) -> String {
        let parts = [f.artistFolder, f.albumFolder].filter { !$0.isEmpty }
        return parts.joined(separator: " / ")
    }

    private func confidenceBadge(_ c: OrphanConfidence) -> some View {
        let (text, color): (String, Color) = c.isConfident ? ("Sicuro", .green) : ("Dubbio", .orange)
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // ── Footer ─────────────────────────────────────────────────────────────────

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Chiudi") { isPresented = false }.keyboardShortcut(.cancelAction)

            if hasScanned && !orphans.isEmpty {
                Button("Seleziona sicuri") {
                    selection = Set(confidentOrphans.map { $0.path })
                }
                .disabled(confidentOrphans.isEmpty)
                Button("Deseleziona") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }

            Spacer()

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if let freed = lastFreed {
                Text("Liberati \(byteString(freed))").font(.caption).foregroundStyle(.secondary)
            }

            if hasScanned && !orphans.isEmpty {
                if !selection.isEmpty {
                    Text("\(selection.count) selezionati · \(byteString(selectedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showTrashConfirm = true
                } label: {
                    if isTrashing {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Label("Sposta nel Cestino", systemImage: "trash")
                    }
                }
                .disabled(selection.isEmpty || isTrashing)
            }
        }
        .padding(16)
    }

    // ── Azioni ─────────────────────────────────────────────────────────────────

    private func runScan() async {
        isScanning = true; errorMessage = nil; lastFreed = nil
        scanned = 0; foundSoFar = 0; selection = []
        do {
            let res = try await appState.orphanService.scan { s, found in
                Task { @MainActor in scanned = s; foundSoFar = found }
            }
            orphans = res.orphans
            totalScanned = res.totalFilesScanned
            referencedCount = res.referencedCount
            mediaFolder = res.mediaFolder
            selection = Set(res.orphans.filter { $0.confidence.isConfident }.map { $0.path })
            hasScanned = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }

    private func runTrash() async {
        let toTrash = selectedFiles
        guard !toTrash.isEmpty else { return }
        isTrashing = true; errorMessage = nil
        do {
            let res = try await appState.orphanService.trashOrphans(toTrash)
            let trashedSet = Set(res.trashed)
            orphans.removeAll { trashedSet.contains($0.path) }
            selection.subtract(trashedSet)
            lastFreed = res.freedBytes
            if !res.failed.isEmpty {
                errorMessage = "\(res.failed.count) file non spostati (vedi log)."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isTrashing = false
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
