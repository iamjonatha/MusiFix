import SwiftUI
import MusiFixCore
import Persistence

/// Lista delle operazioni recenti con supporto undo per batch.
struct OperationLogView: View {
    let appState: AppState
    var onUndone: () -> Void
    @Binding var isPresented: Bool

    @State private var batches: [DBOperation] = []
    @State private var undoingBatchID: String? = nil
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cronologia operazioni")
                    .font(.headline)
                Spacer()
                Button { loadBatches() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Ricarica elenco")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if batches.isEmpty {
                VStack {
                    Spacer()
                    Text("Nessuna operazione recente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(batches, id: \.id) { op in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opSummary(op))
                                .font(.system(size: 12))
                            Text(op.performedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        statusBadge(op)
                        if op.status == "done", let bid = op.batchID {
                            Button("Annulla") { undoBatch(bid) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                                .disabled(undoingBatchID != nil)
                                .overlay {
                                    if undoingBatchID == bid {
                                        ProgressView().scaleEffect(0.6)
                                    }
                                }
                        }
                    }
                }
            }

            if let err = error {
                Divider()
                Text(err).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(width: 400, height: 360)
        .onAppear { loadBatches() }
    }

    private func loadBatches() {
        let db = appState.db
        batches = (try? db.read { db in try OperationDAO.fetchRecentBatches(in: db) }) ?? []
    }

    private func undoBatch(_ batchID: String) {
        undoingBatchID = batchID
        error = nil
        Task {
            do {
                _ = try await appState.writeService.undo(batchID: batchID)
                await MainActor.run {
                    undoingBatchID = nil
                    loadBatches()
                    onUndone()
                }
            } catch {
                await MainActor.run {
                    undoingBatchID = nil
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func opSummary(_ op: DBOperation) -> String {
        let field = op.field == "artwork" ? "Copertina" : op.field
        let after = op.valueAfter ?? ""
        return "\(field): → \"\(after.prefix(40))\""
    }

    private func statusBadge(_ op: DBOperation) -> some View {
        let (label, color): (String, Color) = switch op.status {
        case "done":   ("✔", .green)
        case "failed": ("✘", .red)
        case "undone": ("↩", .secondary)
        default:       ("…", .orange)
        }
        return Text(label)
            .font(.caption.bold())
            .foregroundStyle(color)
    }
}
