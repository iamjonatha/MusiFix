import SwiftUI
import MusiFixCore
import Persistence

/// Dashboard statistiche libreria (F5.3 — UC-01).
/// Pannello a comparsa che mostra i contatori principali e permette di navigare
/// direttamente alle funzioni di correzione corrispondenti.
struct DashboardView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    var onOpenNormalization: () -> Void = {}
    var onOpenDuplicates: () -> Void = {}
    /// Applica il filtro al browser e chiude la dashboard.
    var onFilter: (TrackFilter) -> Void = { _ in }

    @State private var stats: LibraryStats = .zero
    @State private var isLoading = true
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Libreria", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Aggiorna statistiche")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Calcolo statistiche…")
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statGrid
                        Divider()
                        missingFieldsSection
                        Divider()
                        inconsistenciesSection
                        Divider()
                        formatSection
                        Divider()
                        exportReportsSection
                        Divider()
                        maintenanceSection
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                if let date = stats.lastSyncDate {
                    Text("Ultima sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Chiudi") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 680)
        .onAppear { Task { await reload() } }
    }

    // ── Griglia principale ────────────────────────────────────────────────────

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 12) {
            StatCard(value: stats.totalTracks,   label: "Brani totali",  icon: "music.note",  color: .blue)
            StatCard(value: stats.cloudOnly,      label: "Solo iCloud",   icon: "icloud",       color: .teal)
            StatCard(value: stats.deletionCount,  label: "Eliminati",     icon: "trash",        color: .gray)
        }
    }

    // ── Sezione campi mancanti ────────────────────────────────────────────────

    private var missingFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Campi mancanti").font(.subheadline.bold())

            IssueRow(count: stats.missingYear,
                     label: "Anno mancante",
                     icon: "calendar.badge.exclamationmark",
                     color: .orange) {
                navigate(filter: .missingYear)
            }
            IssueRow(count: stats.missingArtist,
                     label: "Artista mancante",
                     icon: "person.badge.minus",
                     color: .red) {
                navigate(filter: .missingArtist)
            }
            IssueRow(count: stats.missingAlbum,
                     label: "Album mancante",
                     icon: "opticaldisc",
                     color: .red) {
                navigate(filter: .missingAlbum)
            }
            IssueRow(count: stats.missingAlbumArtist,
                     label: "Artista album mancante",
                     icon: "person.2.badge.minus",
                     color: .orange) {
                navigate(filter: .missingAlbumArtist)
            }
            IssueRow(count: stats.missingGenre,
                     label: "Genere mancante",
                     icon: "tag.slash",
                     color: .purple) {
                navigate(filter: .missingGenre)
            }
            IssueRow(count: stats.missingTrackNumber,
                     label: "N. traccia mancante",
                     icon: "number.circle",
                     color: .orange) {
                navigate(filter: .missingTrackNumber)
            }
            IssueRow(count: stats.missingDiscNumber,
                     label: "N. disco mancante",
                     icon: "opticaldisc.fill",
                     color: .orange) {
                navigate(filter: .missingDiscNumber)
            }
            if stats.withoutFile > 0 {
                IssueRow(count: stats.withoutFile,
                         label: "File non trovato (non iCloud)",
                         icon: "doc.badge.ellipsis",
                         color: .red) {
                    isPresented = false
                }
            }
        }
    }

    // ── Sezione inconsistenze ─────────────────────────────────────────────────

    private var inconsistenciesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inconsistenze").font(.subheadline.bold())

            IssueRow(count: stats.multipleAlbumValues,
                     label: "Valori multipli per il campo Album",
                     icon: "exclamationmark.triangle",
                     color: .yellow) {
                navigate(filter: .multipleAlbumValues)
            }
            IssueRow(count: stats.multipleAlbumArtistValues,
                     label: "Valori multipli per il campo Artista Album",
                     icon: "person.2.slash",
                     color: .yellow) {
                navigate(filter: .multipleAlbumArtistValues)
            }
        }
    }

    // ── Sezione formati ───────────────────────────────────────────────────────

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Formati audio").font(.subheadline.bold())
            if stats.formatBreakdown.isEmpty {
                Text("Nessun dato.").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(stats.formatBreakdown, id: \.format) { item in
                    HStack {
                        Text(item.format.uppercased())
                            .font(.caption.monospaced())
                            .frame(width: 44, alignment: .leading)
                        ProgressView(value: Double(item.count),
                                     total: Double(stats.totalTracks > 0 ? stats.totalTracks : 1))
                            .tint(formatColor(item.format))
                        Text("\(item.count)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // ── Sezione export report Markdown ────────────────────────────────────────

    private var exportReportsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Esporta report (Markdown)").font(.subheadline.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Button {
                    exportMarkdown(name: "musifix-brani-caricati-\(dateStamp()).md") {
                        try await appState.exportService.uploadedTracksMarkdown()
                    }
                } label: {
                    Label("Brani caricati", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    exportMarkdown(name: "musifix-brani-solo-cloud-\(dateStamp()).md") {
                        try await appState.exportService.cloudOnlyTracksMarkdown()
                    }
                } label: {
                    Label("Brani solo cloud", systemImage: "icloud")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    exportMarkdown(name: "musifix-album-incompleti-\(dateStamp()).md") {
                        try await appState.exportService.incompleteAlbumsMarkdown()
                    }
                } label: {
                    Label("Album incompleti", systemImage: "square.stack.3d.up.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    exportMarkdown(name: "musifix-album-con-caricati-\(dateStamp()).md") {
                        try await appState.exportService.albumsWithUploadedMarkdown()
                    }
                } label: {
                    Label("Album con caricati", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(isExporting)
            .font(.caption)

            if isExporting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Generazione report…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ── Sezione manutenzione ──────────────────────────────────────────────────

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manutenzione").font(.subheadline.bold())

            HStack(spacing: 8) {
                Button { exportDatabase() } label: {
                    Label("Esporta indice DB…", systemImage: "externaldrive.badge.checkmark")
                }
                Button { exportRules() } label: {
                    Label("Esporta regole…", systemImage: "list.bullet.clipboard")
                }
            }
            .font(.caption)

            Text("Ricorda: esegui un backup di Time Machine e copia ~/Music/Music Library.musiclibrary prima di operazioni di massa.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func navigate(filter: TrackFilter) {
        isPresented = false
        onFilter(filter)
    }

    private func reload() async {
        isLoading = true
        let db = appState.db
        let s = try? loadLibraryStats(db: db)
        await MainActor.run {
            stats = s ?? .zero
            isLoading = false
        }
    }

    private func exportDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "musifixindex-backup-\(dateStamp()).db"
        panel.allowedContentTypes = [.init(filenameExtension: "db")!]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let src = appState.dbPath
        try? FileManager.default.copyItem(
            at: URL(fileURLWithPath: src),
            to: dest
        )
    }

    private func exportRules() {
        Task {
            let genreAliases  = (try? await appState.normalizationService.genreAliases())  ?? []
            let artistAliases = (try? await appState.normalizationService.artistAliases()) ?? []

            let payload: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "genreAliases": genreAliases.map { ["from": $0.from, "to": $0.to] },
                "artistAliases": artistAliases.map { ["from": $0.from, "to": $0.to] }
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
            ) else { return }

            await MainActor.run {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "musifixrules-\(dateStamp()).json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let dest = panel.url else { return }
                try? data.write(to: dest)
            }
        }
    }

    /// Genera il report Markdown (async, fuori dal main thread) e poi propone il
    /// salvataggio su file con un NSSavePanel. Un comando per report.
    private func exportMarkdown(name: String, generate: @escaping () async throws -> String) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            let markdown = (try? await generate())
                ?? "# Errore\n\nGenerazione del report non riuscita.\n"
            await MainActor.run {
                isExporting = false
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.allowedContentTypes = [.init(filenameExtension: "md")!]
                guard panel.runModal() == .OK, let dest = panel.url else { return }
                try? markdown.data(using: .utf8)?.write(to: dest)
            }
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
    }

    private func formatColor(_ fmt: String) -> Color {
        switch fmt.lowercased() {
        case "m4a", "aac":    return .blue
        case "mp3":            return .orange
        case "aiff", "aif":   return .green
        case "wav":            return .teal
        case "flac", "alac":  return .purple
        default:               return .gray
        }
    }
}

// ── Componenti UI ─────────────────────────────────────────────────────────────

private struct StatCard: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text("\(value)").font(.title.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct IssueRow: View {
    let count: Int
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(count > 0 ? color : .secondary)
                .frame(width: 20)
            Text(label).font(.caption)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.15))
                    .foregroundStyle(color)
                    .clipShape(Capsule())
                Button("Vai →") { action() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
        }
    }
}
