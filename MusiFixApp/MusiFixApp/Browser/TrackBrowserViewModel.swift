import Foundation
import Persistence
import Combine

@MainActor
final class TrackBrowserViewModel: ObservableObject {
    @Published var tracks: [DBTrack] = [] { didSet { rebuildDisplayRows() } }
    @Published var totalCount: Int = 0
    @Published var sortField: TrackSortField = .artist
    @Published var sortAscending: Bool = true
    @Published var filter: TrackFilter = .none
    @Published var selectedPIDs: Set<String> = []

    /// Brani ignorati direttamente (per PID) e album ignorati (per chiave):
    /// alimentano l'evidenziazione "attenuata" e le voci di menu contestuale. (Fase 13)
    @Published var ignoredTrackPIDs: Set<String> = []
    @Published var ignoredAlbumKeys: Set<String> = []

    /// Raggruppamento per anno di pubblicazione: mostra intestazioni di sezione.
    /// Quando attivo si carica l'intero risultato del filtro (niente paginazione).
    @Published private(set) var groupByYear: Bool = false

    /// Riga di visualizzazione della tabella: intestazione di gruppo oppure brano.
    enum DisplayRow {
        case header(year: Int, count: Int)
        case track(DBTrack)
    }

    /// Modello effettivamente renderizzato dalla tabella. In modalità piatta è la
    /// proiezione 1:1 di `tracks`; in modalità raggruppata intercala gli header.
    @Published private(set) var displayRows: [DisplayRow] = []

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
        let grouped = groupByYear
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Self.offMain { () -> ([DBTrack], Int)? in
                try? db.read { d in
                    if grouped {
                        // Modalità raggruppata: carica l'intero risultato ordinato per
                        // anno (le sezioni richiedono l'insieme completo, niente pagine).
                        let all = try TrackDAO.fetchAllFiltered(
                            filter: f, orderBy: .year, ascending: sa, in: d)
                        return (all, all.count)
                    }
                    return (try TrackDAO.fetchPage(offset: 0, limit: ps, orderBy: sf, ascending: sa, filter: f, in: d),
                            try TrackDAO.countFiltered(filter: f, in: d))
                }
            }
            guard let self, !Task.isCancelled, gen == self.generation, let result else { return }
            self.tracks = result.0
            self.totalCount = result.1
            self.dataVersion &+= 1
        }
    }

    /// Attiva/disattiva il raggruppamento per anno di pubblicazione. Abilitandolo
    /// forza l'ordinamento per anno e ricarica l'intero risultato del filtro.
    func setGroupByYear(_ on: Bool, db: AppDatabase) {
        guard on != groupByYear else { return }
        groupByYear = on
        if on { sortField = .year }
        loadInitialPage(db: db)
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
        guard !isSearching, !groupByYear else { return }
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

    /// Ricostruisce `displayRows` da `tracks`. In modalità piatta è una proiezione
    /// 1:1; in modalità raggruppata ordina per anno (stabile, preservando l'ordine
    /// interno) e intercala un header per ogni anno con il conteggio dei brani.
    private func rebuildDisplayRows() {
        guard groupByYear else {
            displayRows = tracks.map { .track($0) }
            return
        }
        let asc = sortAscending
        // Sort stabile: a parità di anno preserva l'ordine (artista/album) dalla query.
        let sorted = tracks.enumerated().sorted { a, b in
            if a.element.year != b.element.year {
                return asc ? a.element.year < b.element.year : a.element.year > b.element.year
            }
            return a.offset < b.offset
        }.map { $0.element }

        var rows: [DisplayRow] = []
        rows.reserveCapacity(sorted.count + 32)
        var i = 0
        while i < sorted.count {
            let y = sorted[i].year
            var j = i
            while j < sorted.count && sorted[j].year == y { j += 1 }
            rows.append(.header(year: y, count: j - i))
            for k in i..<j { rows.append(.track(sorted[k])) }
            i = j
        }
        displayRows = rows
    }
}
