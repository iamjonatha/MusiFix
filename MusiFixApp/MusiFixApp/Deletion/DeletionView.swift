import SwiftUI
import MusiFixCore
import Persistence

/// Sheet di conferma eliminazione brani (F5.1).
/// Mostra riepilogo, scelta ambito, avviso iCloud e doppia conferma se > soglia.
struct DeletionView: View {
    let tracks: [DBTrack]
    let appState: AppState
    var onDeleted: ([String]) -> Void   // callback con i PID rimossi con successo
    @Binding var isPresented: Bool

    @State private var scope: DeletionScope = .fromMusicOnly
    @State private var phase: Phase = .confirm
    @State private var confirmText = ""
    @State private var isDeleting = false
    @State private var result: DeletionResult? = nil
    @State private var errorMessage: String? = nil

    private enum Phase { case confirm, doubleConfirm, done }

    private let doubleConfirmThreshold = DeletionService.doubleConfirmThreshold

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trash.fill").foregroundStyle(.red)
                Text("Elimina brani").font(.headline)
                Spacer()
                if phase != .done {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(16)

            Divider()

            switch phase {
            case .confirm:       confirmView
            case .doubleConfirm: doubleConfirmView
            case .done:          doneView
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // ── Pannello di conferma ──────────────────────────────────────────────────

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Riepilogo
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Brani selezionati:").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(tracks.count)").font(.caption.bold())
                    }
                    Divider()
                    if tracks.count <= 5 {
                        ForEach(tracks, id: \.persistentID) { t in
                            HStack(spacing: 4) {
                                Text(t.name).font(.caption).lineLimit(1)
                                Text("–").foregroundStyle(.tertiary).font(.caption)
                                Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else {
                        ForEach(Array(tracks.prefix(4)), id: \.persistentID) { t in
                            HStack(spacing: 4) {
                                Text(t.name).font(.caption).lineLimit(1)
                                Text("–").foregroundStyle(.tertiary).font(.caption)
                                Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text("… e altri \(tracks.count - 4) brani").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            // Scelta ambito
            VStack(alignment: .leading, spacing: 6) {
                Text("Cosa vuoi eliminare?").font(.subheadline.bold())

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Solo da Music", systemImage: "music.note")
                            .font(.caption.bold())
                        Text("Rimuove il brano dalla libreria. Il file audio rimane sul disco.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(scope == .fromMusicOnly ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(scope == .fromMusicOnly ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { scope = .fromMusicOnly }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Da Music + Cestino", systemImage: "trash")
                            .font(.caption.bold())
                        Text("Rimuove il brano e sposta il file audio nel Cestino.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(scope == .fromMusicAndTrash ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(scope == .fromMusicAndTrash ? Color.red : Color.secondary.opacity(0.2), lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { scope = .fromMusicAndTrash }
                    .frame(maxWidth: .infinity)
                }
            }

            // Avviso iCloud
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.blue).font(.caption)
                Text("Se la libreria è sincronizzata con iCloud, l'eliminazione sarà propagata anche agli altri dispositivi Apple collegati allo stesso ID Apple.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.blue.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Annulla") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Elimina…", role: .destructive) { proceed() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDeleting)
            }
            .padding(16)
        }
    }

    // ── Doppia conferma ───────────────────────────────────────────────────────

    private var doubleConfirmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conferma eliminazione di massa").font(.subheadline.bold())
                    Text("Stai per eliminare \(tracks.count) brani. Questa operazione non può essere annullata.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Digita **Elimina** per confermare:")
                .font(.caption)

            TextField("Elimina", text: $confirmText)
                .textFieldStyle(.roundedBorder)

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Indietro") { phase = .confirm; confirmText = "" }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isDeleting { ProgressView().scaleEffect(0.8) }
                Button("Elimina definitivamente", role: .destructive) { performDeletion() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(confirmText != "Elimina" || isDeleting)
            }
            .padding(16)
        }
    }

    // ── Pannello risultato ────────────────────────────────────────────────────

    private var doneView: some View {
        VStack(spacing: 12) {
            if let r = result {
                if r.allSucceeded {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.green)
                    Text("Eliminati \(r.succeeded.count) brani.").font(.subheadline.bold())
                    if !r.trashedPaths.isEmpty {
                        Text("\(r.trashedPaths.count) file spostati nel Cestino.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
                    Text("\(r.succeeded.count) riusciti, \(r.failed.count) falliti.").font(.subheadline.bold())
                    if let (_, msg) = r.failed.first {
                        Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                }
            }
        }
        .padding(24)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Chiudi") {
                    if let r = result { onDeleted(r.succeeded) }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    // ── Logica ───────────────────────────────────────────────────────────────

    private func proceed() {
        errorMessage = nil
        if tracks.count >= doubleConfirmThreshold {
            phase = .doubleConfirm
        } else {
            performDeletion()
        }
    }

    private func performDeletion() {
        isDeleting = true; errorMessage = nil
        let tracksToDelete = tracks
        let chosenScope = scope
        Task {
            do {
                let r = try await appState.deletionService.delete(
                    tracks: tracksToDelete,
                    scope: chosenScope
                )
                await MainActor.run {
                    result = r
                    isDeleting = false
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDeleting = false
                }
            }
        }
    }
}
