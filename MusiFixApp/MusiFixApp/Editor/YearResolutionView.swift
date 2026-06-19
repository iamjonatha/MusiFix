import SwiftUI
import MusiFixCore
import Persistence

/// Sheet per il recupero assistito dell'anno di **prima pubblicazione** di un brano.
/// Mostra l'anno attuale, quello suggerito (anno minimo plausibile dai provider) e
/// tutti i candidati. L'utente conferma; la scrittura passa da `writeService` ed è
/// quindi annullabile dal Log operazioni.
struct YearResolutionView: View {
    let track: DBTrack
    let appState: AppState
    var onApplied: () -> Void
    @Binding var isPresented: Bool

    @State private var isLoading = true
    @State private var resolution: YearResolution? = nil
    @State private var selectedYear: Int? = nil
    @State private var isApplying = false
    @State private var applyError: String? = nil
    @State private var appliedOK = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .task { await load() }
    }

    // ── Header ──────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recupera anno di pubblicazione")
                    .font(.headline)
                Text("\(track.artist) — \(track.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(16)
    }

    // ── Contenuto ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Ricerca su MusicBrainz…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let res = resolution {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary(res)
                    if res.candidates.isEmpty {
                        ContentUnavailableView(
                            "Nessun candidato trovato",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Nessun provider ha restituito un anno affidabile per questo brano.")
                        )
                        .padding(.top, 12)
                    } else {
                        Text("Candidati")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(res.candidates) { cand in
                            candidateRow(cand, suggested: cand.year == res.suggestedYear)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func summary(_ res: YearResolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                labeledYear("Attuale", res.currentYear > 0 ? "\(res.currentYear)" : "—",
                            color: .secondary)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                labeledYear("Suggerito", res.suggestedYear.map(String.init) ?? "—",
                            color: res.changesYear ? .accentColor : .secondary)
            }

            if res.currentYearLikelyReissue {
                Label(
                    "L'album sembra una ristampa/remaster: l'anno attuale è probabilmente quello dell'edizione, non dell'originale.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !res.changesYear && res.suggestedYear != nil {
                Label("L'anno attuale coincide già con quello originale.",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func labeledYear(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title2).fontWeight(.semibold).foregroundStyle(color)
        }
    }

    private func candidateRow(_ cand: YearCandidate, suggested: Bool) -> some View {
        let isSelected = selectedYear == cand.year
        return Button {
            selectedYear = cand.year
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text("\(cand.year)")
                    .font(.system(.body, design: .rounded)).fontWeight(.semibold)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cand.sourceTitle).font(.caption).lineLimit(1)
                    Text(cand.artistName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if suggested {
                    Text("suggerito")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(cand.provider).font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", cand.confidence * 100))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── Footer ──────────────────────────────────────────────────────────────────

    private var footer: some View {
        HStack {
            if let err = applyError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if appliedOK {
                Label("Anno aggiornato — annullabile dal Log operazioni",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if isApplying {
                ProgressView().scaleEffect(0.6)
            }
            Spacer()
            Button("Annulla") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Applica anno") { apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .padding(16)
        .background(.bar)
    }

    private var canApply: Bool {
        guard !isApplying, !appliedOK, track.isEditable, let y = selectedYear else { return false }
        return y != track.year
    }

    // ── Azioni ──────────────────────────────────────────────────────────────────

    private func load() async {
        isLoading = true
        let res = await appState.yearResolutionService.resolveYear(
            title: track.name,
            artist: track.artist,
            album: track.album,
            currentYear: track.year,
            durationSeconds: track.duration
        )
        await MainActor.run {
            resolution = res
            selectedYear = res.suggestedYear
            isLoading = false
        }
    }

    private func apply() {
        guard let year = selectedYear else { return }
        let pid = track.persistentID
        isApplying = true
        applyError = nil
        Task {
            do {
                let result = try await appState.writeService.write(
                    TrackMetadataUpdate(year: year), for: pid
                )
                await MainActor.run {
                    isApplying = false
                    if result.allSucceeded {
                        appliedOK = true
                        onApplied()
                    } else if let (_, msg) = result.failed.first {
                        applyError = msg
                    }
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    applyError = error.localizedDescription
                }
            }
        }
    }
}
