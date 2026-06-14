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

    private var searchTask: Task<Void, Never>?
    private let pageSize = 200

    func loadInitialPage(db: AppDatabase) {
        // Snapshot @MainActor state before Sendable closure
        let sf = sortField; let sa = sortAscending; let f = filter; let ps = pageSize
        do {
            let result = try db.read { d in
                (
                    try TrackDAO.fetchPage(offset: 0, limit: ps, orderBy: sf, ascending: sa, filter: f, in: d),
                    try TrackDAO.countFiltered(filter: f, in: d)
                )
            }
            tracks = result.0
            totalCount = result.1
        } catch {
            print("TrackBrowser load error: \(error)")
        }
    }

    func search(query: String, db: AppDatabase) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try db.read { d in
                    try TrackDAO.search(query: query, offset: 0, limit: 500, in: d)
                }
                self.tracks = results
                self.totalCount = results.count
            } catch {
                print("Search error: \(error)")
            }
        }
    }

    func sort(by field: TrackSortField, db: AppDatabase) {
        if sortField == field { sortAscending.toggle() } else { sortField = field; sortAscending = true }
        loadInitialPage(db: db)
    }

    func loadMoreIfNeeded(currentIndex: Int, db: AppDatabase) {
        let currentCount = tracks.count
        guard currentIndex >= currentCount - 50, currentCount < totalCount else { return }
        let sf = sortField; let sa = sortAscending; let f = filter; let ps = pageSize
        do {
            let more = try db.read { d in
                try TrackDAO.fetchPage(offset: currentCount, limit: ps, orderBy: sf, ascending: sa, filter: f, in: d)
            }
            tracks.append(contentsOf: more)
        } catch {
            print("LoadMore error: \(error)")
        }
    }
}
