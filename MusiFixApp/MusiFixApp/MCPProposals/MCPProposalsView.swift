import SwiftUI
import MusiFixCore
import Persistence

/// Pannello "Proposte AI" (Fase 25): controlli del server MCP e coda delle
/// proposte di scrittura in attesa di approvazione dell'utente.
struct MCPProposalsView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    var onApplied: () -> Void

    @State private var proposals: [MCPProposalService.Proposal] = []
    @State private var loading = false
    @State private var busyID: String?
    @State private var copiedEndpoint = false

    @AppStorage(AppState.mcpPortKey) private var port = Int(MCPServerService.defaultPort)
    @AppStorage(AppState.mcpTokenKey) private var token = ""
    @AppStorage(AppState.mcpAutoApplyKey) private var autoApply = false
    @AppStorage(AppState.mcpAutoStartKey) private var autoStart = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            serverSection
            Divider()
            if proposals.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(proposals) { proposal in
                            proposalCard(proposal)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: reload)
    }

    // ── Header ─────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            Image(systemName: "sparkles.rectangle.stack")
            Text("Proposte AI").font(.headline)
            Spacer()
            Button {
                reload()
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Ricarica")
            Button("Chiudi") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // ── Sezione server ─────────────────────────────────────────────────────────

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Semaforo di stato: verde = attivo, rosso = spento.
                Circle()
                    .fill(appState.mcpServerRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: (appState.mcpServerRunning ? Color.green : Color.red).opacity(0.6),
                            radius: 3)
                Text(appState.mcpServerRunning ? "Server MCP attivo" : "Server MCP spento")
                    .font(.subheadline.bold())
                Spacer()
                Button(appState.mcpServerRunning ? "Ferma" : "Avvia") {
                    appState.toggleMCPServer()
                }
                .buttonStyle(.borderedProminent)
            }

            if appState.mcpServerRunning {
                HStack(spacing: 8) {
                    Text("Endpoint:").font(.caption).foregroundStyle(.secondary)
                    Button {
                        copyEndpoint()
                    } label: {
                        HStack(spacing: 5) {
                            Text(endpointURL)
                                .font(.caption.monospaced())
                            Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .foregroundStyle(copiedEndpoint ? Color.green : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Copia l'endpoint negli appunti")
                    Text(token.isEmpty ? "· senza token" : "· richiede Bearer token")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let err = appState.mcpServerError {
                Text("Errore avvio: \(err)")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Porta")
                    TextField("8765", value: $port, format: .number.grouping(.never))
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.mcpServerRunning)
                }
                HStack(spacing: 4) {
                    Text("Token")
                    SecureField("(facoltativo)", text: $token)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.mcpServerRunning)
                }
            }
            .font(.caption)

            Toggle("Applica automaticamente le scritture (salta l'approvazione)", isOn: $autoApply)
                .font(.caption)
                .onChange(of: autoApply) { _, _ in if appState.mcpServerRunning { restartServer() } }
            Toggle("Avvia il server all'apertura dell'app", isOn: $autoStart)
                .font(.caption)

            if autoApply {
                Label("Con l'auto-approvazione un agente AI scrive su Music senza conferma. L'undo resta disponibile dalla cronologia.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // ── Coda proposte ──────────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Nessuna proposta in attesa")
                .foregroundStyle(.secondary)
            Text("Le richieste di modifica inviate da un agente AI compaiono qui in attesa della tua approvazione.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func proposalCard(_ proposal: MCPProposalService.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text("\(proposal.items.count) brani")
                    .font(.subheadline.bold())
                Spacer()
                Text(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(proposal.items.prefix(12)) { item in
                    itemRow(item)
                }
                if proposal.items.count > 12 {
                    Text("… e altri \(proposal.items.count - 12) brani")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Rifiuta", role: .destructive) { reject(proposal.id) }
                    .disabled(busyID != nil)
                Button("Applica a \(proposal.items.count) brani") { apply(proposal.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busyID != nil)
            }
            if busyID == proposal.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func itemRow(_ item: MCPProposalService.Proposal.Item) -> some View {
        let title = item.before.map { "\($0.artist.isEmpty ? "" : "\($0.artist) — ")\($0.name)" }
            ?? item.persistentID
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).lineLimit(1)
            ForEach(changes(for: item), id: \.field) { c in
                HStack(alignment: .top, spacing: 6) {
                    Text(c.field)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    if let before = c.before, !before.isEmpty {
                        Text(before).font(.caption2).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Text(c.after).font(.caption2).foregroundStyle(.primary)
                }
            }
        }
    }

    // ── Diff campo per campo ────────────────────────────────────────────────────

    private struct Change { let field: String; let before: String?; let after: String }

    private func changes(for item: MCPProposalService.Proposal.Item) -> [Change] {
        let u = item.update
        let b = item.before
        var out: [Change] = []
        func add(_ label: String, _ before: String?, _ after: String?) {
            if let after { out.append(Change(field: label, before: before, after: after)) }
        }
        add("Titolo", b?.name, u.name)
        add("Artista", b?.artist, u.artist)
        add("Album Artist", b?.albumArtist, u.albumArtist)
        add("Album", b?.album, u.album)
        add("Anno", b.map { $0.year > 0 ? "\($0.year)" : "" }, u.year.map(String.init))
        add("Genere", b?.genre, u.genre)
        add("Commento", b?.comment, u.comment)
        add("Compositore", b?.composer, u.composer)
        add("N. traccia", b.map { "\($0.trackNumber)" }, u.trackNumber.map(String.init))
        add("Tot. tracce", b.map { "\($0.trackCount)" }, u.trackCount.map(String.init))
        add("N. disco", b.map { "\($0.discNumber)" }, u.discNumber.map(String.init))
        add("Tot. dischi", b.map { "\($0.discCount)" }, u.discCount.map(String.init))
        return out
    }

    // ── Azioni ──────────────────────────────────────────────────────────────────

    private var endpointURL: String { "http://127.0.0.1:\(port)" }

    /// Copia l'endpoint negli appunti e mostra un feedback temporaneo.
    private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
        copiedEndpoint = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedEndpoint = false
        }
    }

    private func reload() {
        loading = true
        Task {
            let list = (try? await appState.mcpProposalService.pending()) ?? []
            proposals = list
            loading = false
            appState.refreshMCPPendingCount()
        }
    }

    private func apply(_ id: String) {
        busyID = id
        Task {
            _ = try? await appState.mcpProposalService.apply(proposalID: id)
            busyID = nil
            onApplied()
            reload()
        }
    }

    private func reject(_ id: String) {
        busyID = id
        Task {
            try? await appState.mcpProposalService.reject(proposalID: id)
            busyID = nil
            reload()
        }
    }

    private func restartServer() {
        appState.stopMCPServer()
        // Riavvio ritardato per lasciare chiudere la porta.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            appState.startMCPServer()
        }
    }
}
