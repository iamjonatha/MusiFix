import SwiftUI
import AppKit
import Persistence
import MusiFixCore

// ── Impostazioni visualizzazione tabella (persistenti) ────────────────────────

final class TableDisplaySettings: ObservableObject {
    @AppStorage("tableRowHeight") var rowHeight: Double = 22
    @AppStorage("tableFontSize") var fontSize: Double = 12
    /// Evidenziazioni condizionali di riga (Fase 15).
    @AppStorage("highlightNotInPlaylist") var highlightNotInPlaylist: Bool = false
    @AppStorage("highlightMissingArtwork") var highlightMissingArtwork: Bool = false
}

// ── TrackTableView ────────────────────────────────────────────────────────────

/// NSTableView view-based virtualizzato, wrappato in SwiftUI.
/// Gestisce 25k+ righe con scrolling fluido grazie al row reuse.
struct TrackTableView: NSViewRepresentable {
    @ObservedObject var viewModel: TrackBrowserViewModel
    @ObservedObject var displaySettings: TableDisplaySettings
    let db: AppDatabase
    let bridge: any AppleMusicBridge
    var onMarkAsSingle: ([String]) -> Void = { _ in }
    var onSetPosition1of1: ([String]) -> Void = { _ in }
    /// (pids, ignora) — ignora/riabilita i brani indicati.
    var onSetIgnore: ([String], Bool) -> Void = { _, _ in }
    /// (brano di riferimento per la chiave album, ignora) — ignora/riabilita l'album.
    var onSetAlbumIgnore: (DBTrack, Bool) -> Void = { _, _ in }
    /// Apre la ricerca Google embedded per il brano indicato.
    var onWebSearch: (DBTrack) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = displaySettings.rowHeight
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        context.coordinator.tableView = tableView

        // Context menu right-click
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        // Colonne
        for col in TrackColumn.allCases {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            tc.title = col.title
            tc.width = col.defaultWidth
            tc.minWidth = 40
            tc.resizingMask = [.autoresizingMask, .userResizingMask]
            if let sf = col.sortField {
                tc.sortDescriptorPrototype = NSSortDescriptor(key: sf.rawValue, ascending: true)
            }
            tableView.addTableColumn(tc)
        }

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
        context.coordinator.fontSize = displaySettings.fontSize
        context.coordinator.onMarkAsSingle = onMarkAsSingle
        context.coordinator.onSetPosition1of1 = onSetPosition1of1
        context.coordinator.onSetIgnore = onSetIgnore
        context.coordinator.onSetAlbumIgnore = onSetAlbumIgnore
        context.coordinator.onWebSearch = onWebSearch
        context.coordinator.highlightNotInPlaylist = displaySettings.highlightNotInPlaylist
        context.coordinator.highlightMissingArtwork = displaySettings.highlightMissingArtwork
        let tv = context.coordinator.tableView
        if let tv, tv.rowHeight != displaySettings.rowHeight {
            tv.rowHeight = displaySettings.rowHeight
            tv.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tv.numberOfRows))
        }
        // Aggiorna indicatore sort nell'header
        if let tv, let col = TrackColumn.allCases.first(where: { $0.sortField == viewModel.sortField }),
           let tc = tv.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(col.rawValue)) {
            tv.highlightedTableColumn = tc
            tv.setIndicatorImage(
                viewModel.sortAscending
                    ? NSImage(named: "NSAscendingSortIndicator")!
                    : NSImage(named: "NSDescendingSortIndicator")!,
                in: tc
            )
        }
        // Ricarica SOLO quando i dati cambiano davvero: SwiftUI chiama updateNSView
        // anche al solo cambio di selezione, e un reloadData() di 25k righe a ogni
        // click è inutile (stutter/flicker). La selezione è riapplicata sotto comunque.
        let dataChanged = context.coordinator.lastDataVersion != viewModel.dataVersion
        context.coordinator.lastDataVersion = viewModel.dataVersion
        if dataChanged { tv?.reloadData() }

        // Reload anche se cambia lo stato di evidenziazione condizionale (toggle o
        // set ricaricati), così le righe si ridisegnano senza un cambio dati.
        let hlSig = "\(displaySettings.highlightNotInPlaylist)|\(displaySettings.highlightMissingArtwork)|\(viewModel.notInPlaylistPIDs.count)|\(viewModel.missingArtworkPIDs.count)"
        if context.coordinator.lastHighlightSig != hlSig {
            context.coordinator.lastHighlightSig = hlSig
            if !dataChanged { tv?.reloadData() }
        }
        // Ripristina la selezione (reloadData la azzera; e va riflessa anche quando
        // cambia in modo programmatico senza reload).
        if let tv {
            let pids = viewModel.selectedPIDs
            let rows = viewModel.displayRows
            let idxs = IndexSet(rows.indices.filter {
                if case .track(let t) = rows[$0] { return pids.contains(t.persistentID) }
                return false
            })
            context.coordinator.suppressSelectionCallback = true
            tv.selectRowIndexes(idxs, byExtendingSelection: false)
            context.coordinator.suppressSelectionCallback = false
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(viewModel: viewModel, db: db, bridge: bridge, fontSize: displaySettings.fontSize)
        c.onMarkAsSingle = onMarkAsSingle
        c.onSetPosition1of1 = onSetPosition1of1
        c.onSetIgnore = onSetIgnore
        c.onSetAlbumIgnore = onSetAlbumIgnore
        c.onWebSearch = onWebSearch
        return c
    }

    // ── Coordinator ───────────────────────────────────────────────────────────

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var viewModel: TrackBrowserViewModel
        let db: AppDatabase
        let bridge: any AppleMusicBridge
        weak var tableView: NSTableView?
        var suppressSelectionCallback = false
        /// Ultima `dataVersion` riflessa nella tabella; -1 forza il primo reload.
        var lastDataVersion = -1
        var fontSize: Double
        var highlightNotInPlaylist = false
        var highlightMissingArtwork = false
        /// Firma dello stato evidenziazione: forza reload quando cambia (Fase 15).
        var lastHighlightSig = ""
        var onMarkAsSingle: ([String]) -> Void = { _ in }
        var onSetPosition1of1: ([String]) -> Void = { _ in }
        var onSetIgnore: ([String], Bool) -> Void = { _, _ in }
        var onSetAlbumIgnore: (DBTrack, Bool) -> Void = { _, _ in }
        var onWebSearch: (DBTrack) -> Void = { _ in }
        private var menuTargetPIDs: [String] = []
        private var menuTargetTrack: DBTrack?
        private var menuIgnoreTracksToOn = true
        private var menuAlbumIgnoreToOn = true

        /// True se il brano è escluso in MusiFix (direttamente o via album ignorato).
        private func isIgnored(_ t: DBTrack) -> Bool {
            if viewModel.ignoredTrackPIDs.contains(t.persistentID) { return true }
            let key = IgnoreService.albumKey(albumArtist: t.albumArtist, artist: t.artist, album: t.album)
            return viewModel.ignoredAlbumKeys.contains(key)
        }

        init(viewModel: TrackBrowserViewModel, db: AppDatabase, bridge: any AppleMusicBridge, fontSize: Double) {
            self.viewModel = viewModel
            self.db = db
            self.bridge = bridge
            self.fontSize = fontSize
        }

        // ── Context menu ──────────────────────────────────────────────────────

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView else { return }
            let row = tv.clickedRow >= 0 ? tv.clickedRow : tv.selectedRow
            guard row >= 0, let clickedTrack = track(atRow: row) else { return }

            if let path = clickedTrack.locationPath {
                let finderItem = NSMenuItem(
                    title: "Mostra nel Finder",
                    action: #selector(showInFinder(_:)),
                    keyEquivalent: ""
                )
                finderItem.representedObject = path
                finderItem.target = self
                menu.addItem(finderItem)
            }

            let musicItem = NSMenuItem(
                title: "Mostra in Music",
                action: #selector(showInMusic(_:)),
                keyEquivalent: ""
            )
            musicItem.representedObject = clickedTrack.persistentID
            musicItem.target = self
            menu.addItem(musicItem)

            let googleItem = NSMenuItem(
                title: "Cerca su Google",
                action: #selector(webSearchAction(_:)),
                keyEquivalent: ""
            )
            googleItem.target = self
            menu.addItem(googleItem)

            // ── Azioni su selezione: "- Single" ─────────────────────────────────
            // Usa la selezione corrente; se il click è fuori dalla selezione,
            // opera sulla sola riga cliccata.
            var rows = tv.selectedRowIndexes
            if tv.clickedRow >= 0, !rows.contains(tv.clickedRow) {
                rows = IndexSet(integer: tv.clickedRow)
            }
            menuTargetPIDs = rows.compactMap { track(atRow: $0)?.persistentID }
            if !menuTargetPIDs.isEmpty {
                menu.addItem(.separator())
                let singleItem = NSMenuItem(
                    title: menuTargetPIDs.count == 1
                        ? "Segna come \u{201C}- Single\u{201D}"
                        : "Segna come \u{201C}- Single\u{201D} (\(menuTargetPIDs.count) brani)",
                    action: #selector(markAsSingleAction(_:)),
                    keyEquivalent: ""
                )
                singleItem.target = self
                menu.addItem(singleItem)

                let posItem = NSMenuItem(
                    title: menuTargetPIDs.count == 1
                        ? "Imposta posizione 1 di 1"
                        : "Imposta posizione 1 di 1 (\(menuTargetPIDs.count) brani)",
                    action: #selector(setPosition1of1Action(_:)),
                    keyEquivalent: ""
                )
                posItem.target = self
                menu.addItem(posItem)
            }

            // ── Ignora in MusiFix (brano + album) ───────────────────────────────
            menu.addItem(.separator())
            menuTargetTrack = clickedTrack

            // Brani: toggle in base a se almeno uno è già ignorato direttamente.
            let anyDirectlyIgnored = menuTargetPIDs.contains { viewModel.ignoredTrackPIDs.contains($0) }
            menuIgnoreTracksToOn = !anyDirectlyIgnored
            let n = menuTargetPIDs.count
            let ignoreTitle: String
            if anyDirectlyIgnored {
                ignoreTitle = n == 1 ? "Non ignorare più il brano" : "Non ignorare più (\(n) brani)"
            } else {
                ignoreTitle = n == 1 ? "Ignora brano in MusiFix" : "Ignora \(n) brani in MusiFix"
            }
            let ignoreItem = NSMenuItem(title: ignoreTitle,
                                        action: #selector(toggleIgnoreTracksAction(_:)), keyEquivalent: "")
            ignoreItem.target = self
            menu.addItem(ignoreItem)

            // Album del brano cliccato.
            let albumKey = IgnoreService.albumKey(
                albumArtist: clickedTrack.albumArtist, artist: clickedTrack.artist, album: clickedTrack.album)
            let albumIgnored = viewModel.ignoredAlbumKeys.contains(albumKey)
            menuAlbumIgnoreToOn = !albumIgnored
            if !clickedTrack.album.isEmpty {
                let albumTitle = albumIgnored
                    ? "Non ignorare più l'album \u{201C}\(clickedTrack.album)\u{201D}"
                    : "Ignora album \u{201C}\(clickedTrack.album)\u{201D}"
                let albumItem = NSMenuItem(title: albumTitle,
                                           action: #selector(toggleIgnoreAlbumAction(_:)), keyEquivalent: "")
                albumItem.target = self
                menu.addItem(albumItem)
            }
        }

        @objc func toggleIgnoreTracksAction(_ sender: NSMenuItem) {
            onSetIgnore(menuTargetPIDs, menuIgnoreTracksToOn)
        }

        @objc func toggleIgnoreAlbumAction(_ sender: NSMenuItem) {
            guard let t = menuTargetTrack else { return }
            onSetAlbumIgnore(t, menuAlbumIgnoreToOn)
        }

        @objc func webSearchAction(_ sender: NSMenuItem) {
            guard let t = menuTargetTrack else { return }
            onWebSearch(t)
        }

        @objc func markAsSingleAction(_ sender: NSMenuItem) {
            onMarkAsSingle(menuTargetPIDs)
        }

        @objc func setPosition1of1Action(_ sender: NSMenuItem) {
            onSetPosition1of1(menuTargetPIDs)
        }

        @objc func showInFinder(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }

        @objc func showInMusic(_ sender: NSMenuItem) {
            guard let pid = sender.representedObject as? String else { return }
            let b = bridge
            Task {
                do {
                    try await b.revealInMusic(persistentID: pid)
                } catch {
                    print("[TrackTableView] revealInMusic fallito per \(pid): \(error)")
                }
            }
        }

        // ── Mappatura riga di visualizzazione → brano ──────────────────────────
        /// Restituisce il brano alla riga `row` di `displayRows`, o nil se la riga
        /// è un'intestazione di gruppo o fuori range.
        private func track(atRow row: Int) -> DBTrack? {
            let rows = viewModel.displayRows
            guard row >= 0, row < rows.count else { return nil }
            if case .track(let t) = rows[row] { return t }
            return nil
        }

        private func isHeaderRow(_ row: Int) -> Bool {
            let rows = viewModel.displayRows
            guard row >= 0, row < rows.count else { return false }
            if case .header = rows[row] { return true }
            return false
        }

        // DataSource
        func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.displayRows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let rows = viewModel.displayRows
            guard row < rows.count else { return nil }

            switch rows[row] {
            case .header(let year, let count):
                // Group row: NSTableView estende a tutta la larghezza la view della
                // prima colonna, quindi la costruiamo solo lì.
                guard tableColumn?.identifier.rawValue == TrackColumn.allCases.first?.rawValue
                else { return nil }
                let id = NSUserInterfaceItemIdentifier("HeaderCell")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
                    ?? {
                        let f = NSTextField(labelWithString: "")
                        f.identifier = id
                        f.isBordered = false
                        f.drawsBackground = false
                        return f
                    }()
                let label = year > 0 ? String(year) : "Senza anno"
                cell.stringValue = "\(label)  ·  \(count) brani"
                cell.font = .boldSystemFont(ofSize: fontSize)
                cell.textColor = .secondaryLabelColor
                cell.lineBreakMode = .byTruncatingTail
                return cell

            case .track(let track):
                guard let colID = tableColumn?.identifier,
                      let col = TrackColumn(rawValue: colID.rawValue) else { return nil }
                let id = NSUserInterfaceItemIdentifier("TextCell")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CenteredTextField
                    ?? CenteredTextField(labelWithString: "")
                cell.identifier = id
                cell.font = .systemFont(ofSize: fontSize)
                cell.lineBreakMode = .byTruncatingTail
                cell.stringValue = col.value(for: track)
                // Precedenza colore: ignorato (più attenuato) > cloud-only > normale.
                if isIgnored(track) {
                    cell.textColor = .tertiaryLabelColor
                } else {
                    cell.textColor = track.isCloudOnly ? .secondaryLabelColor : .labelColor
                }
                return cell
            }
        }

        // Le intestazioni di gruppo sono full-width e non selezionabili.
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            isHeaderRow(row)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            !isHeaderRow(row)
        }

        // Evidenziazione condizionale di riga (Fase 15)
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("HighlightRow")
            let rv = tableView.makeView(withIdentifier: id, owner: nil) as? HighlightRowView
                ?? {
                    let v = HighlightRowView()
                    v.identifier = id
                    return v
                }()
            rv.highlightColor = highlightColor(forRow: row)
            return rv
        }

        private func highlightColor(forRow row: Int) -> NSColor? {
            guard let t = track(atRow: row) else { return nil }
            if highlightMissingArtwork, viewModel.missingArtworkPIDs.contains(t.persistentID) {
                return NSColor.systemBlue.withAlphaComponent(0.12)
            }
            if highlightNotInPlaylist, viewModel.notInPlaylistPIDs.contains(t.persistentID) {
                return NSColor.systemOrange.withAlphaComponent(0.13)
            }
            return nil
        }

        // Paginazione progressiva
        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            Task { @MainActor in
                viewModel.loadMoreIfNeeded(currentIndex: row, db: db)
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let sd = tableView.sortDescriptors.first,
                  let key = sd.key,
                  let sf = TrackSortField(rawValue: key) else { return }
            viewModel.sort(by: sf, ascending: sd.ascending, db: db)
        }

        @objc func rowClicked(_ sender: Any) {}

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let tv = tableView else { return }
            var pids = Set<String>()
            tv.selectedRowIndexes.forEach { row in
                if let t = track(atRow: row) { pids.insert(t.persistentID) }
            }
            viewModel.selectedPIDs = pids
        }
    }
}

// ── Riga con tinta di evidenziazione condizionale (Fase 15) ───────────────────

private final class HighlightRowView: NSTableRowView {
    var highlightColor: NSColor? {
        didSet { if highlightColor != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let color = highlightColor else { return }
        color.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

// ── NSTextField con testo centrato verticalmente ──────────────────────────────

private final class CenteredTextField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        // Centra verticalmente ridefinendo il frame interno prima del disegno
        if let cell = self.cell {
            let textHeight = cell.cellSize(forBounds: bounds).height
            let offsetY = (bounds.height - textHeight) / 2
            var adjusted = bounds
            adjusted.origin.y = offsetY
            adjusted.size.height = textHeight
            cell.draw(withFrame: adjusted, in: self)
        } else {
            super.draw(dirtyRect)
        }
    }
}

// ── Colonne ───────────────────────────────────────────────────────────────────

enum TrackColumn: String, CaseIterable {
    case status, name, artist, albumArtist, album, year, genre, duration, bitRate, format

    var title: String {
        switch self {
        case .status:      return "Stato"
        case .name:        return "Titolo"
        case .artist:      return "Artista"
        case .albumArtist: return "Album Artist"
        case .album:       return "Album"
        case .year:        return "Anno"
        case .genre:       return "Genere"
        case .duration:    return "Durata"
        case .bitRate:     return "kbps"
        case .format:      return "Formato"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .status:      return 90
        case .name:        return 220
        case .artist:      return 160
        case .albumArtist: return 140
        case .album:       return 160
        case .year:        return 50
        case .genre:       return 90
        case .duration:    return 60
        case .bitRate:     return 50
        case .format:      return 45
        }
    }

    var sortField: TrackSortField? {
        switch self {
        case .name:        return .name
        case .artist:      return .artist
        case .albumArtist: return .albumArtist
        case .album:       return .album
        case .year:        return .year
        case .genre:       return .genre
        case .duration:    return .duration
        case .status, .bitRate, .format: return nil
        }
    }

    func value(for t: DBTrack) -> String {
        switch self {
        case .status:
            let cs = CloudStatus(code: t.cloudStatus)
            switch cs {
            case .matched:      return "≈ Abbinato"
            case .uploaded:     return "↑ Caricato"
            case .purchased:    return "Acquistato"
            case .subscription: return "Apple Music"
            // cloudStatus assente: distingui in base al flag isCloudOnly (file locale
            // trovato o no), così la colonna è coerente col filtro "Solo cloud".
            case .none:         return t.isCloudOnly ? "☁ Cloud" : "✓ Locale"
            default:            return t.isCloudOnly ? "☁ Cloud" : "✓ Locale"
            }
        case .name:        return t.name
        case .artist:      return t.artist
        case .albumArtist: return t.albumArtist
        case .album:       return t.album
        case .year:        return t.year > 0 ? "\(t.year)" : ""
        case .genre:       return t.genre
        case .duration:
            let s = Int(t.duration)
            return String(format: "%d:%02d", s / 60, s % 60)
        case .bitRate:     return t.bitRate > 0 ? "\(t.bitRate)" : ""
        case .format:
            let f = t.format.uppercased()
            if !f.isEmpty { return f }
            // Cloud-only: estrai estensione dal kind (es. "File audio AAC" → "AAC")
            let words = t.kind.components(separatedBy: " ")
            return words.last(where: { ["AAC","MP3","MPEG","AIFF","WAV","FLAC","ALAC","M4A"].contains($0.uppercased()) })?.uppercased() ?? ""
        }
    }
}
