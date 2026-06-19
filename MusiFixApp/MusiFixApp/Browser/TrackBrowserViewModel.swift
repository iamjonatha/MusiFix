import Foundation
import Persistence
import Combine

@MainActor
final class TrackBrowserViewModel: ObservableObject {
    @Published var tracks: [DBTrack] = []
    @Published var totalCount: Int = 0
    @Published var sortField: TrackSortField = .artist
    @Published var sortAscending: Bool = true
    @Published var filter: TrackFilter = .none
    @Published var selectedPIDs: Set<String> = []

    /// Incrementato a ogni cambio effettivo del contenuto di `tracks` (load/sort/
    /// append/search). La tabella AppKit la usa per ricaricarsi SOLO quando i dati
    /// cambiano davvero, non a ogni variazione di selezione.
    @Published private(set) var dataVersion: Int = 0

    var selectedTracks: [DBTrack] {
        let pids = selectedPIDs
        return tracks.filter { pids.contains($0.persistentID) }
    }

    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Cambia a ogni load/sort/search: invalida i loadMore in volo che si riferiscono
    /// a un filtro/ordinamento ormai superato.
    private var generation = 0
    private var isSearching = false
    private let pageSize = 200

    func loadInitialPage(db: AppDatabase) {
        isSearching = false
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let sf = sortField; let sa = sortAscending; let f = filter; let ps = pageSize
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Self.offMain { () -> ([DBTrack], Int)? in
                try? db.read { d in
                    (try TrackDAO.fetchPage(offset: 0, limit: ps, orderBy: sf, ascending: sa, filter: f, in: d),
                     try TrackDAO.countFiltered(filter: f, in: d))
                }
            }
            guard let self, !Task.isCancelled, gen == self.generation, let result else { return }
            self.tracks = result.0
            self.totalCount = result.1
            self.dataVersion &+= 1
        }
    }

    func search(query: String, db: AppDatabase) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Query vuota: torna alla paginazione normale del filtro corrente.
        guard !trimmed.isEmpty else {
            loadInitialPage(db: db)
            return
        }
        loadTask?.cancel()
        searchTask?.cancel()
        generation += 1
        let gen = generation
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let results = await Self.offMain { () -> [DBTrack]? in
                try? db.read { d in try TrackDAO.search(query: query, offset: 0, limit: 500, in: d) }
            }
            guard !Task.isCancelled, gen == self.generation, let results else { return }
            self.tracks = results
            self.totalCount = results.count
            self.dataVersion &+= 1
        }
    }

    func sort(by field: TrackSortField, db: AppDatabase) {
        if sortField == field { sortAscending.toggle() } else { sortField = field; sortAscending = true }
        loadInitialPage(db: db)
    }

    func sort(by field: TrackSortField, ascending: Bool, db: AppDatabase) {
        sortField = field
        sortAscending = ascending
        loadInitialPage(db: db)
    }

    func loadMoreIfNeeded(currentIndex: Int, db: AppDatabase) {
        guard !isSearching else { return }
        let currentCount = tracks.count
        guard currentIndex >= currentCount - 50, currentCount < totalCount else { return }
        let gen = generation
        let sf = sortField; let sa = sortAscending; let f = filter; let ps = pageSize
        Task { [weak self] in
            let more = await Self.offMain { () -> [DBTrack]? in
                try? db.read { d in
                    try TrackDAO.fetchPage(offset: currentCount, limit: ps, orderBy: sf, ascending: sa, filter: f, in: d)
                }
            }
            // Applica solo se il set non è cambiato sotto di noi (stesso filtro/sort e
            // nessun altro append nel frattempo): evita duplicati e righe del filtro
            // sbagliato quando più loadMore partono vicino al fondo.
            guard let self, gen == self.generation, self.tracks.count == currentCount,
                  let more, !more.isEmpty else { return }
            self.tracks.append(contentsOf: more)
            self.dataVersion &+= 1
        }
    }

    /// Esegue lavoro bloccante (lettura GRDB) fuori dal main thread, così il browser
    /// non blocca la UI durante sort/filtro/paginazione su 25k brani.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
