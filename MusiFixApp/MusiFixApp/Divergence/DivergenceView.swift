import SwiftUI
import MusiFixCore
import Persistence

// MARK: - ViewModel

@MainActor
final class DivergenceViewModel: ObservableObject {
    enum Phase {
        case detecting
        case results([TrackDivergence])
        case applying
        case done(succeeded: Int, failed: Int)
        case failed(String)
    }

    @Published var phase: Phase = .detecting
    @Published var choices: [String: Bool] = [:]   // pid → true=useDB, false=useMusic

    private let service: DivergenceService
    private let pids: [String]

    init(service: DivergenceService, pids: [String]) {
        self.service = service
        self.pids = pids
    }

    func detect() {
        phase = .detecting
        Task {
            do {
                let divergences = try await service.detect(pids: pids)
                choices = Dictionary(uniqueKeysWithValues: divergences.map { ($0.persistentID, true) })
                phase = .results(divergences)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func setAll(useDB: Bool, for divergences: [TrackDivergence]) {
        for d in divergences { choices[d.persistentID] = useDB }
    }

    func applyAll(_ divergences: [TrackDivergence]) {
        phase = .applying
        Task {
            var succeeded = 0
            var failed = 0
            for div in divergences {
                do {
                    if choices[div.persistentID] ?? true {
                        try await service.applyDB(div)
                    } else {
                        try await service.applyMusic(div)
                    }
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }
            phase = .done(succeeded: succeeded, failed: failed)
        }
    }
}

// MARK: - View

struct DivergenceView: View {
    @StateObject private var vm: DivergenceViewModel
    @Binding var isPresented: Bool
    let onApplied: () -> Void

    init(
        service: DivergenceService,
        pids: [String],
        isPresented: Binding<Bool>,
        onApplied: @escaping () -> Void
    ) {
        _vm = StateObject(wrappedValue: DivergenceViewModel(service: service, pids: pids))
        _isPresented = isPresented
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Verifica vs Music.app").font(.headline)
                Spacer()
                if case .results(let divs) = vm.phase, !divs.isEmpty {
                    Text("\(divs.count) \(divs.count == 1 ? "divergenza" : "divergenze")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            mainContent
        }
        .frame(width: 560, height: 500)
        .onAppear { vm.detect() }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch vm.phase {
        case .detecting:
            centeredStatus {
                ProgressView()
                Text("Confronto con Music.app…").font(.caption).foregroundStyle(.secondary)
            }

        case .results(let divs) where divs.isEmpty:
            centeredStatus {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Nessuna divergenza").font(.headline)
                Text("Tutti i brani selezionati sono allineati con Music.app.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } footer: {
                Button("Chiudi") { isPresented = false }.buttonStyle(.borderedProminent)
            }

        case .results(let divs):
            VStack(spacing: 0) {
                // Azioni batch
                HStack {
                    Text("Scegli la fonte per ogni brano").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("DB per tutti")    { vm.setAll(useDB: true,  for: divs) }.font(.caption)
                    Button("Music per tutti") { vm.setAll(useDB: false, for: divs) }.font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                Divider()

                List(divs) { div in
                    DivergenceRowView(
                        divergence: div,
                        useDB: Binding(
                            get: { vm.choices[div.persistentID] ?? true },
                            set: { vm.choices[div.persistentID] = $0 }
                        )
                    )
                }
                .listStyle(.plain)

                Divider()

                HStack {
                    Button("Annulla") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Applica \(divs.count) \(divs.count == 1 ? "brano" : "brani")") {
                        vm.applyAll(divs)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }

        case .applying:
            centeredStatus {
                ProgressView()
                Text("Applicazione in corso…").font(.caption).foregroundStyle(.secondary)
            }

        case .done(let succeeded, let failed):
            centeredStatus {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(failed == 0 ? Color.green : Color.orange)
                Text(failed == 0 ? "Completato" : "Completato con errori").font(.headline)
                Text("\(succeeded) aggiornati\(failed > 0 ? " · \(failed) errori" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Button("Chiudi") { onApplied(); isPresented = false }.buttonStyle(.borderedProminent)
            }

        case .failed(let msg):
            centeredStatus {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("Errore").font(.headline)
                Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } footer: {
                Button("Chiudi") { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func centeredStatus<C: View>(
        @ViewBuilder content: () -> C,
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 12) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            HStack { Spacer(); footer() }.padding(16)
        }
    }
}

// MARK: - Row

private struct DivergenceRowView: View {
    let divergence: TrackDivergence
    @Binding var useDB: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(divergence.displayName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $useDB) {
                    Text("DB").tag(true)
                    Text("Music").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
            }

            ForEach(divergence.fields) { field in
                HStack(alignment: .top, spacing: 8) {
                    Text(field.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        fieldBadge(label: "DB",    value: field.dbValue,    active: useDB)
                        fieldBadge(label: "Music", value: field.musicValue, active: !useDB)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func fieldBadge(label: String, value: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .cornerRadius(3)
            Text(value.isEmpty ? "(vuoto)" : value)
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
                .strikethrough(!active, color: .secondary)
                .lineLimit(1)
        }
    }
}
