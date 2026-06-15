import SwiftUI
import MusiFixCore
import Persistence

/// Sheet per normalizzazione generi e artisti.
/// Tab 1: Anteprima impatto (con esclusioni per riga).
/// Tab 2: Gestione alias dizionario.
struct NormalizationView: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var selectedTab = 0
    @State private var genrePreviews: [NormalizationPreview] = []
    @State private var artistPreviews: [NormalizationPreview] = []
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var excludedIDs: Set<UUID> = []
    @State private var resultMessage: String? = nil
    @State private var genreAliases: [(from: String, to: String)] = []
    @State private var artistAliases: [(from: String, to: String)] = []
    @State private var newAliasFrom = ""; @State private var newAliasTo = ""
    @State private var aliasTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Normalizzazione").font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            TabView(selection: $selectedTab) {
                previewTab.tabItem { Label("Anteprima", systemImage: "wand.and.stars") }.tag(0)
                aliasTab_view.tabItem { Label("Alias", systemImage: "list.bullet") }.tag(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider()

            // Footer
            HStack {
                Button("Annulla") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if let msg = resultMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                if isApplying { ProgressView().scaleEffect(0.7) }
                Button("Applica selezionati") { applySelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || selectedPreviews.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 520)
        .onAppear { Task { await loadPreviews() } }
    }

    // ── Tab Anteprima ─────────────────────────────────────────────────────────

    private var previewTab: some View {
        VStack(spacing: 8) {
            Picker("Campo", selection: $selectedTab) {
                Text("Generi (\(genrePreviews.count))").tag(0)
                Text("Artisti (\(artistPreviews.count))").tag(1)
            }.pickerStyle(.segmented).padding(.top, 4)

            if isLoading {
                Spacer()
                ProgressView("Calcolo impatto…")
                Spacer()
            } else {
                let previews = selectedTab == 0 ? genrePreviews : artistPreviews
                if previews.isEmpty {
                    Spacer()
                    Text("Nessuna normalizzazione da applicare.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Table(previews) {
                        TableColumn("") { p in
                            Toggle("", isOn: Binding(
                                get: { !excludedIDs.contains(p.id) },
                                set: { if $0 { excludedIDs.remove(p.id) } else { excludedIDs.insert(p.id) } }
                            )).labelsHidden()
                        }.width(24)
                        TableColumn("Valore originale") { p in
                            Text(p.originalValue).font(.system(size: 12, design: .monospaced))
                        }
                        TableColumn("→") { _ in Text("→").foregroundStyle(.secondary) }.width(20)
                        TableColumn("Normalizzato") { p in
                            Text(p.normalizedValue).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        TableColumn("Brani") { p in
                            Text("\(p.trackCount)").foregroundStyle(.secondary)
                        }.width(50)
                    }
                }
            }
        }
    }

    // ── Tab Alias ─────────────────────────────────────────────────────────────

    private var aliasTab_view: some View {
        VStack(spacing: 8) {
            Picker("Tipo", selection: $aliasTab) {
                Text("Generi").tag(0)
                Text("Artisti").tag(1)
            }.pickerStyle(.segmented).padding(.top, 4)

            let aliases = aliasTab == 0 ? genreAliases : artistAliases
            List {
                ForEach(aliases, id: \.from) { alias in
                    HStack {
                        Text(alias.from).font(.system(size: 12, design: .monospaced))
                        Text("→").foregroundStyle(.secondary)
                        Text(alias.to).foregroundStyle(.blue)
                        Spacer()
                        Button(role: .destructive) { removeAlias(alias.from) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }.buttonStyle(.plain)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("da (es. hip hop)", text: $newAliasFrom).frame(maxWidth: 180)
                Text("→")
                TextField("a (es. Hip-Hop)", text: $newAliasTo).frame(maxWidth: 180)
                Button("Aggiungi") { addAlias() }
                    .disabled(newAliasFrom.isEmpty || newAliasTo.isEmpty)
            }
            .padding(.bottom, 8)
        }
        .onChange(of: aliasTab) { _, _ in loadAliases() }
        .onAppear { loadAliases() }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var selectedPreviews: [NormalizationPreview] {
        let all = selectedTab == 0 ? genrePreviews : artistPreviews
        return all.filter { !excludedIDs.contains($0.id) }
    }

    private func loadPreviews() async {
        isLoading = true
        do {
            async let g = appState.normalizationService.previewGenreNormalization()
            async let a = appState.normalizationService.previewArtistNormalization()
            genrePreviews = try await g
            artistPreviews = try await a
        } catch {
            resultMessage = "Errore: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func applySelected() {
        isApplying = true; resultMessage = nil
        Task {
            do {
                let excluded = Set(
                    (selectedTab == 0 ? genrePreviews : artistPreviews)
                        .filter { excludedIDs.contains($0.id) }
                        .map(\.originalValue)
                )
                let result = try await appState.normalizationService.applyNormalization(
                    selectedTab == 0 ? genrePreviews : artistPreviews,
                    excluding: excluded
                )
                await MainActor.run {
                    resultMessage = "Aggiornati: \(result.updated)\(result.failed > 0 ? " · Errori: \(result.failed)" : "")"
                    isApplying = false
                }
                await loadPreviews()
            } catch {
                await MainActor.run { resultMessage = error.localizedDescription; isApplying = false }
            }
        }
    }

    private func loadAliases() {
        Task {
            genreAliases  = (try? await appState.normalizationService.genreAliases())  ?? []
            artistAliases = (try? await appState.normalizationService.artistAliases()) ?? []
        }
    }

    private func addAlias() {
        let from = newAliasFrom; let to = newAliasTo
        Task {
            if aliasTab == 0 { try? await appState.normalizationService.addGenreAlias(from: from, to: to) }
            else             { try? await appState.normalizationService.addArtistAlias(from: from, to: to) }
            newAliasFrom = ""; newAliasTo = ""
            loadAliases()
        }
    }

    private func removeAlias(_ from: String) {
        Task {
            if aliasTab == 0 { try? await appState.normalizationService.removeGenreAlias(from: from) }
            else             { try? await appState.normalizationService.removeArtistAlias(from: from) }
            loadAliases()
        }
    }
}
