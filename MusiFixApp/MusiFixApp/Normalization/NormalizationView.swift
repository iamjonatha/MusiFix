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
    @State private var previewField = 0   // 0=Generi, 1=Artisti — separato da selectedTab
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

    // Tab "Simili"
    @State private var similarGroups: [ArtistSimilarityGroup] = []
    @State private var groupNames: [UUID: String] = [:]           // nome normalizzato scelto per gruppo
    @State private var groupExcluded: [UUID: Set<String>] = [:]   // varianti escluse per gruppo
    @State private var isFindingSimilar = false
    @State private var unifyingGroup: UUID? = nil
    @State private var similarityThreshold: Double = 0.82

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
                similarTab.tabItem { Label("Simili", systemImage: "person.2.badge.gearshape") }.tag(1)
                aliasTab_view.tabItem { Label("Alias", systemImage: "list.bullet") }.tag(2)
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
                if selectedTab != 1 {
                    Button("Applica selezionati") { applySelected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplying || selectedPreviews.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 520)
        .onAppear { Task { await loadPreviews() } }
    }

    // ── Tab Anteprima ─────────────────────────────────────────────────────────

    private var previewTab: some View {
        VStack(spacing: 8) {
            Picker("Campo", selection: $previewField) {
                Text("Generi (\(genrePreviews.count))").tag(0)
                Text("Artisti (\(artistPreviews.count))").tag(1)
            }.pickerStyle(.segmented).padding(.top, 4)

            if isLoading {
                Spacer()
                ProgressView("Calcolo impatto…")
                Spacer()
            } else {
                let previews = previewField == 0 ? genrePreviews : artistPreviews
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

    // ── Tab Simili ────────────────────────────────────────────────────────────

    private var similarTab: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Gruppi di artisti scritti in modo diverso ma probabilmente uguali. "
                     + "Indica il nome normalizzato e unifica.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await findSimilar() }
                } label: {
                    Label("Ricalcola", systemImage: "arrow.clockwise")
                }.disabled(isFindingSimilar)
            }
            .padding(.top, 4)

            HStack(spacing: 8) {
                Text("Soglia similitudine").font(.caption).foregroundStyle(.secondary)
                Slider(value: $similarityThreshold, in: 0.60...0.98, step: 0.01) {
                    Text("Soglia")
                } minimumValueLabel: {
                    Text("permissiva").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("rigida").font(.caption2).foregroundStyle(.secondary)
                }
                Text(String(format: "%.2f", similarityThreshold))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }

            if isFindingSimilar {
                Spacer(); ProgressView("Ricerca similitudini…"); Spacer()
            } else if similarGroups.isEmpty {
                Spacer()
                Text("Nessun gruppo di artisti simili individuato.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(similarGroups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { if similarGroups.isEmpty { Task { await findSimilar() } } }
    }

    @ViewBuilder
    private func groupCard(_ group: ArtistSimilarityGroup) -> some View {
        let excluded = groupExcluded[group.id] ?? []
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.variants) { v in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { !excluded.contains(v.name) },
                            set: { on in
                                var set = groupExcluded[group.id] ?? []
                                if on { set.remove(v.name) } else { set.insert(v.name) }
                                groupExcluded[group.id] = set
                            }
                        )).labelsHidden()
                        Text(v.name).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text("\(v.trackCount)").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Normalizza a:").font(.caption).foregroundStyle(.secondary)
                    TextField("nome normalizzato", text: Binding(
                        get: { groupNames[group.id] ?? group.suggestedName },
                        set: { groupNames[group.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    if unifyingGroup == group.id {
                        ProgressView().scaleEffect(0.6)
                    }
                    Button("Unifica") { unify(group) }
                        .buttonStyle(.borderedProminent)
                        .disabled(unifyingGroup != nil
                                  || (groupNames[group.id] ?? group.suggestedName)
                                      .trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(4)
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
        let all = previewField == 0 ? genrePreviews : artistPreviews
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
                    (previewField == 0 ? genrePreviews : artistPreviews)
                        .filter { excludedIDs.contains($0.id) }
                        .map(\.originalValue)
                )
                let result = try await appState.normalizationService.applyNormalization(
                    previewField == 0 ? genrePreviews : artistPreviews,
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

    private func findSimilar() async {
        isFindingSimilar = true; resultMessage = nil
        do {
            let groups = try await appState.normalizationService.findSimilarArtists(
                threshold: similarityThreshold)
            await MainActor.run {
                similarGroups = groups
                groupExcluded = [:]
                groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.suggestedName) })
                isFindingSimilar = false
            }
        } catch {
            await MainActor.run {
                resultMessage = "Errore: \(error.localizedDescription)"
                isFindingSimilar = false
            }
        }
    }

    private func unify(_ group: ArtistSimilarityGroup) {
        let target = (groupNames[group.id] ?? group.suggestedName)
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let excluded = groupExcluded[group.id] ?? []
        let variants = group.variants.map(\.name).filter { !excluded.contains($0) }
        guard !variants.isEmpty else { return }

        unifyingGroup = group.id; resultMessage = nil
        Task {
            do {
                let result = try await appState.normalizationService.unifyArtists(
                    variants: variants, to: target)
                await MainActor.run {
                    resultMessage = "Unificati: \(result.updated)\(result.failed > 0 ? " · Errori: \(result.failed)" : "")"
                    similarGroups.removeAll { $0.id == group.id }
                    unifyingGroup = nil
                }
            } catch {
                await MainActor.run {
                    resultMessage = error.localizedDescription
                    unifyingGroup = nil
                }
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
