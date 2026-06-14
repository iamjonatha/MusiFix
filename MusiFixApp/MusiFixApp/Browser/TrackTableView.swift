import SwiftUI
import AppKit
import Persistence

/// NSTableView view-based virtualizzato, wrappato in SwiftUI.
/// Gestisce 25k+ righe con scrolling fluido grazie al row reuse.
struct TrackTableView: NSViewRepresentable {
    @ObservedObject var viewModel: TrackBrowserViewModel
    let db: AppDatabase

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        context.coordinator.tableView = tableView

        // Colonne
        for col in TrackColumn.allCases {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            tc.title = col.title
            tc.width = col.defaultWidth
            tc.minWidth = 40
            tc.resizingMask = [.autoresizingMask, .userResizingMask]
            // Header click → sort
            let headerCell = NSTableHeaderCell()
            headerCell.stringValue = col.title
            tc.headerCell = headerCell
            tableView.addTableColumn(tc)
        }

        // Header click sort
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.tableView?.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, db: db)
    }

    // ── Coordinator ───────────────────────────────────────────────────────────

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var viewModel: TrackBrowserViewModel
        let db: AppDatabase
        weak var tableView: NSTableView?

        init(viewModel: TrackBrowserViewModel, db: AppDatabase) {
            self.viewModel = viewModel
            self.db = db
        }

        // DataSource
        func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.tracks.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < viewModel.tracks.count,
                  let colID = tableColumn?.identifier,
                  let col = TrackColumn(rawValue: colID.rawValue) else { return nil }

            let track = viewModel.tracks[row]
            let id = NSUserInterfaceItemIdentifier("TextCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            cell.lineBreakMode = .byTruncatingTail
            cell.stringValue = col.value(for: track)

            // Testo grigio per track cloud-only
            cell.textColor = track.isCloudOnly ? .secondaryLabelColor : .labelColor
            return cell
        }

        // Paginazione progressiva
        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            Task { @MainActor in
                viewModel.loadMoreIfNeeded(currentIndex: row, db: db)
            }
        }

        @objc func rowClicked(_ sender: Any) {}

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = tableView else { return }
            var pids = Set<String>()
            tv.selectedRowIndexes.forEach { row in
                if row < viewModel.tracks.count {
                    pids.insert(viewModel.tracks[row].persistentID)
                }
            }
            viewModel.selectedPIDs = pids
        }
    }
}

// ── Colonne ───────────────────────────────────────────────────────────────────

enum TrackColumn: String, CaseIterable {
    case name, artist, albumArtist, album, year, genre, duration, bitRate, format

    var title: String {
        switch self {
        case .name:       return "Titolo"
        case .artist:     return "Artista"
        case .albumArtist: return "Album Artist"
        case .album:      return "Album"
        case .year:       return "Anno"
        case .genre:      return "Genere"
        case .duration:   return "Durata"
        case .bitRate:    return "kbps"
        case .format:     return "Formato"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name:       return 220
        case .artist:     return 160
        case .albumArtist: return 140
        case .album:      return 160
        case .year:       return 50
        case .genre:      return 90
        case .duration:   return 60
        case .bitRate:    return 50
        case .format:     return 45
        }
    }

    func value(for t: DBTrack) -> String {
        switch self {
        case .name:       return t.name
        case .artist:     return t.artist
        case .albumArtist: return t.albumArtist
        case .album:      return t.album
        case .year:       return t.year > 0 ? "\(t.year)" : ""
        case .genre:      return t.genre
        case .duration:
            let s = Int(t.duration)
            return String(format: "%d:%02d", s / 60, s % 60)
        case .bitRate:    return t.bitRate > 0 ? "\(t.bitRate)" : ""
        case .format:     return t.format.uppercased()
        }
    }
}
