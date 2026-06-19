import SwiftUI
import MusiFixCore
import Persistence

// ── View model ────────────────────────────────────────────────────────────────

/// Orchestratore della risoluzione anni in batch: scorre i brani, interroga
/// `YearResolutionService` (rate-limited al suo interno) e raccoglie le proposte,
/// poi applica le scelte accettate via `MetadataWriteService` (annullabili dal Log).
@MainActor
final class BatchYearViewModel: ObservableObject {
    enum Phase: Equatable { case idle, resolving, review, applying, done }

    struct Row: Identifiable {
        let track: DBTrack
        var resolution: YearResolution?
        var chosenYear: Int?        // anno scelto (nil = "non cambiare")
        var accepted: Bool          // includere nell'applicazione
        var id: String { track.persistentID }

        /// True se la scelta corrente modificherebbe davvero l'anno del brano.
        var hasChange: Bool {
            guard let y = chosenYear else { return false }
            return y != track.year
        }
    }

    @Published var phase: Phase = .idle
    @Published var rows: [Row]
    @Published var resolvedCount = 0
    @Published var applyResultMessage: String?

    private let service: YearResolutionService
    private let writeService: MetadataWriteService
    private var task: Task<Void, Never>?

    init(tracks: [DBTrack], service: YearResolutionService, writeService: MetadataWriteService) {
        self.service = service
        self.writeService = writeService
        self.rows = tracks.map { Row(track: $0, resolution: nil, chosenYear: nil, accepted: false) }
    }

    var total: Int { rows.count }
    var acceptedCount: Int { rows.filter { $0.accepted && $0.hasChange && $0.track.isEditable }.count }

    func start() {
        guard phase == .idle else { return }
        phase = .resolving
        resolvedCount = 0
        task = Task { [weak self] in
            guard let self else { return }
            for idx in self.rows.indices {
                if Task.isCancelled { break }
                let t = self.rows[idx].track
                let res = await self.service.resolveYear(
                    title: t.name, artist: t.artist, album: t.album,
                    currentYear: t.year, durationSeconds: t.duration
                )
                if Task.isCancelled { break }
                self.rows[idx].resolution = res
                // Default: proponi il suggerimento e pre-accettalo solo se cambia
                // davvero l'anno e il brano è scrivibile.
                self.rows[idx].chosenYear = res.suggestedYear
                self.rows[idx].accepted = t.isEditable && res.changesYear
                self.resolvedCount += 1
            }
            if !Task.isCancelled { self.phase = .review }
        }
    }

    func cancelResolving() {
        task?.cancel()
        // Conserva quanto già risolto per la revisione; se nulla, torna idle.
        phase = rows.contains { $0.resolution != nil } ? .review : .idle
    }

    func setChosenYear(_ year: Int?, for id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].chosenYear = year
        if year == nil { rows[i].accepted = false }
        else if rows[i].track.isEditable { rows[i].accepted = true }
    }

    func toggleAccepted(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].accepted.toggle()
    }

    func apply(onApplied: @escaping () -> Void) {
        let items: [(TrackMetadataUpdate, String)] = rows.compactMap { r in
            guard r.accepted, r.hasChange, r.track.isEditable, let y = r.chosenYear else { return nil }
            return (TrackMetadataUpdate(year: y), r.track.persistentID)
        }
        guard !items.isEmpty else { return }
        phase = .applying
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.writeService.writeBatch(items)
                self.applyResultMessage = result.failed.isEmpty
                    ? "Anno aggiornato per \(result.succeeded.count) brani — annullabile dal Log operazioni."
                    : "Aggiornati \(result.succeeded.count), falliti \(result.failed.count)."
            } catch {
                self.applyResultMessage = "Errore: \(error.localizedDescription)"
            }
            self.phase = .done
            onApplied()
        }
    }
}

// ── View ──────────────────────────────────────────────────────────────────────

/// Sheet per il recupero in blocco dell'anno di **prima pubblicazione** su più brani
/// (tipicamente quelli filtrati per "Anno mancante"). Mostra la proposta per ogni
/// brano, permette di scegliere il candidato o escludere il brano, e applica in batch.
struct BatchYearResolutionView: View {
    @StateObject private var vm: BatchYearViewModel
    @Binding var isPresented: Bool
    var onApplied: () -> Void

    init(tracks: [DBTrack], appState: AppState, isPresented: Binding<Bool>, onApplied: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: BatchYearViewModel(
            tracks: tracks,
            service: appState.yearResolutionService,
            writeService: appState.writeService
        ))
        _isPresented = isPresented
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.phase == .resolving { progressStrip; Divider() }
            table
            Divider()
            footer
        }
        .frame(width: 640, height: 580)
        .onAppear { vm.start() }
    }

    // ── Header ──────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recupera anni di pubblicazione")
                    .font(.headline)
                Text("\(vm.total) brani · anno minimo plausibile da MusicBrainz/iTunes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(16)
    }

    private var progressStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(vm.resolvedCount), total: Double(max(vm.total, 1)))
            Text("Ricerca anni… \(vm.resolvedCount)/\(vm.total) (≈1 sec/brano per il limite di MusicBrainz)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // ── Tabella ─────────────────────────────────────────────────────────────────

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.rows) { row in
                    rowView(row)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: BatchYearViewModel.Row) -> some View {
        HStack(spacing: 10) {
            Button { vm.toggleAccepted(row.id) } label: {
                Image(systemName: row.accepted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(row.accepted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canAccept(row))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.track.name).font(.callout).lineLimit(1)
                Text(row.track.artist.isEmpty ? "—" : row.track.artist)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            if row.resolution?.currentYearLikelyReissue == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("L'album sembra una ristampa/remaster: l'anno attuale è probabilmente quello dell'edizione.")
            }
            if !row.track.isEditable {
                Image(systemName: "icloud")
                    .foregroundStyle(.tertiary)
                    .help("Brano cloud-only: non scrivibile.")
            }

            HStack(spacing: 6) {
                Text(row.track.year > 0 ? "\(row.track.year)" : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption2)
                candidatePicker(row)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .opacity(row.track.isEditable ? 1 : 0.55)
    }

    @ViewBuilder
    private func candidatePicker(_ row: BatchYearViewModel.Row) -> some View {
        if let res = row.resolution {
            if res.candidates.isEmpty {
                Text("nessuno")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 100, alignment: .trailing)
            } else {
                Menu {
                    Button("Non cambiare") { vm.setChosenYear(nil, for: row.id) }
                    Divider()
                    ForEach(uniqueYears(res), id: \.self) { y in
                        Button {
                            vm.setChosenYear(y, for: row.id)
                        } label: {
                            Text(y == res.suggestedYear ? "\(y)  — suggerito" : "\(y)")
                        }
                    }
                } label: {
                    Text(row.chosenYear.map { "\($0)" } ?? "non cambiare")
                        .monospacedDigit()
                        .foregroundStyle(row.hasChange ? Color.accentColor : .secondary)
                }
                .fixedSize()
                .frame(width: 110, alignment: .trailing)
                .disabled(!row.track.isEditable)
            }
        } else if vm.phase == .resolving {
            ProgressView().scaleEffect(0.5).frame(width: 100, alignment: .trailing)
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: 100, alignment: .trailing)
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch vm.phase {
            case .idle, .resolving:
                if vm.phase == .resolving { ProgressView().scaleEffect(0.6) }
                Text("Ricerca \(vm.resolvedCount)/\(vm.total)…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Interrompi") { vm.cancelResolving() }
                    .disabled(vm.phase != .resolving)
            case .review:
                Text("\(vm.acceptedCount) brani da aggiornare")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annulla") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Applica a \(vm.acceptedCount) brani") {
                    vm.apply(onApplied: onApplied)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.acceptedCount == 0)
            case .applying:
                ProgressView().scaleEffect(0.6)
                Text("Scrittura su Music…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .done:
                if let m = vm.applyResultMessage {
                    Label(m, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green).lineLimit(2)
                }
                Spacer()
                Button("Chiudi") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.bar)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────────

    private func canAccept(_ row: BatchYearViewModel.Row) -> Bool {
        row.track.isEditable && row.resolution != nil && row.chosenYear != nil && row.hasChange
    }

    private func uniqueYears(_ res: YearResolution) -> [Int] {
        Array(Set(res.candidates.map(\.year))).sorted()
    }
}
