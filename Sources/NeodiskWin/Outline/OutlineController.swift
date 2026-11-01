// Feeds the outline from the workspace: the drilled-in folder's children, largest first, with expanded
// folders' children flattened under them. Rows exist only for expanded levels, so a deep tree stays cheap.

import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

@MainActor
final class OutlineController {
    private struct Row {
        let id: String
        let depth: Int
    }

    private let view: OutlineView
    private let workspace: ScanWorkspace
    private var rows: [Row] = []
    private var rowIndex: [String: Int] = [:]
    private var expanded: Set<String> = []
    private var builtFor: (generation: Int, rootID: String?)?
    private var observations: [ChangeObservation] = []
    /// Search matches, best first, while the search field has text; nil shows the tree.
    private var resultIDs: [String]?
    private var query = ""
    private let searchIndex = SearchIndexService()
    private let debouncer = SearchDebouncer()
    static let resultLimit = 200
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(view: OutlineView, workspace: ScanWorkspace) {
        self.view = view
        self.workspace = workspace
        view.cellText = { [unowned self] row, column in self.text(row: row, column: column) }
        view.rowShape = { [unowned self] row in self.shape(row: row) }
        view.onToggle = { [unowned self] row in self.toggle(row: row) }
        view.onActivate = { [unowned self] row in
            guard self.rows.indices.contains(row) else { return }
            if !self.workspace.drillIn(to: self.rows[row].id) { MessageBeep(UINT(MB_OK)) }
        }
        view.onSelectionChange = { [unowned self] selected, _ in
            let ids = selected.compactMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil }
            let extending = isKeyDown(VK_CONTROL) || isKeyDown(VK_SHIFT)
            self.workspace.select(fromList: ids, extending: extending, listShows: { self.rowIndex[$0] != nil })
        }
        view.onKey = { [unowned self] key in self.handleKey(key) }

        observations.append(observeChanges { [unowned self] in
            _ = self.workspace.storeGeneration
            _ = self.workspace.focusedRootID
            self.rebuild()
        })
        observations.append(observeChanges { [unowned self] in
            _ = self.workspace.selection
            self.syncSelection()
        })
    }

    // MARK: - Rows

    private func rebuild() {
        if resultIDs != nil {
            // The tree changed under the matches (a refresh): search it again.
            search(query)
            return
        }
        guard let store = workspace.store, let rootID = workspace.focusedRootID else {
            rows = []
            rowIndex = [:]
            builtFor = nil
            view.reload(count: 0, keepScroll: false)
            return
        }
        let sameRoot = builtFor?.rootID == rootID
        if !sameRoot { expanded = [] }
        builtFor = (workspace.storeGeneration, rootID)
        var fresh: [Row] = []
        func append(childrenOf parentID: String, depth: Int) {
            for child in store.children(of: parentID) {
                fresh.append(Row(id: child.id, depth: depth))
                if expanded.contains(child.id) {
                    append(childrenOf: child.id, depth: depth + 1)
                }
            }
        }
        append(childrenOf: rootID, depth: 0)
        rows = fresh
        reindex()
        // A tree streaming in keeps the scroll position; a new root starts at the top.
        view.reload(count: rows.count, keepScroll: sameRoot)
        syncSelection()
    }

    // MARK: - Search

    /// Fuzzy search over every scanned name, off the main actor. Filtering never navigates: the map moves only
    /// when a match is picked.
    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let snapshot = workspace.snapshot else {
            debouncer.cancel()
            if resultIDs != nil {
                resultIDs = nil
                rebuild()
            }
            return
        }
        let query = self.query
        let snapshotID = snapshot.id
        debouncer.schedule { [weak self] in
            guard let self else { return }
            let index = await self.searchIndex.index(for: snapshot)
            guard !Task.isCancelled, self.workspace.snapshot?.id == snapshotID, self.query == query else { return }
            let entries = index.entries
            let rootID = index.rootID
            let limit = Self.resultLimit
            let matches = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit) { $0.id != rootID }
            }.value
            guard !Task.isCancelled, self.query == query else { return }
            self.showResults(matches.ids)
        }
    }

    private func showResults(_ ids: [String]) {
        resultIDs = ids
        rows = ids.map { Row(id: $0, depth: 0) }
        reindex()
        view.reload(count: rows.count, keepScroll: false)
        view.redraw(rows: 0...max(0, rows.count - 1))
        syncSelection()
    }

    /// Enter in the search field: the best match.
    func pickFirstResult() {
        guard let first = resultIDs?.first else { return }
        workspace.select(first)
    }

    private func reindex() {
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func isExpandable(_ id: String, in store: FileTreeStore) -> Bool {
        guard let node = store.node(id: id), node.isDirectory else { return false }
        return store.containsChildren(id: id)
    }

    private func toggle(row: Int) {
        guard rows.indices.contains(row) else { return }
        setExpanded(row: row, !expanded.contains(rows[row].id))
    }

    private func setExpanded(row: Int, _ expand: Bool) {
        guard resultIDs == nil, let store = workspace.store, rows.indices.contains(row) else { return }
        let id = rows[row].id
        guard isExpandable(id, in: store), expand != expanded.contains(id) else { return }
        if expand {
            expanded.insert(id)
            var inserted: [Row] = []
            func append(childrenOf parentID: String, depth: Int) {
                for child in store.children(of: parentID) {
                    inserted.append(Row(id: child.id, depth: depth))
                    if expanded.contains(child.id) { append(childrenOf: child.id, depth: depth + 1) }
                }
            }
            append(childrenOf: id, depth: rows[row].depth + 1)
            rows.insert(contentsOf: inserted, at: row + 1)
        } else {
            expanded.remove(id)
            let depth = rows[row].depth
            var end = row + 1
            while end < rows.count, rows[end].depth > depth { end += 1 }
            rows.removeSubrange((row + 1)..<end)
        }
        reindex()
        view.reload(count: rows.count, keepScroll: true)
        view.redraw(rows: row...max(row, rows.count - 1))
        syncSelection()
    }

    /// Opens the folders down to `id`, so a selection made elsewhere (the map) shows in the list.
    private func reveal(_ id: String) {
        guard resultIDs == nil, rowIndex[id] == nil, let store = workspace.store, let rootID = workspace.focusedRootID,
              store.isAncestor(rootID, of: id) else { return }
        var chain: [String] = []
        var current = store.parent(of: id)?.id
        while let folder = current, folder != rootID {
            chain.append(folder)
            current = store.parent(of: folder)?.id
        }
        for folder in chain.reversed() {
            if let row = rowIndex[folder] { setExpanded(row: row, true) }
        }
    }

    private func syncSelection() {
        if let primary = workspace.selection.primaryID { reveal(primary) }
        let selected = workspace.selection.ids.compactMap { rowIndex[$0] }
        let focused = workspace.selection.primaryID.flatMap { rowIndex[$0] }
        guard Set(selected) != Set(view.selectedRows) || (focused != nil && focused != view.focusedRow) else { return }
        view.setSelection(selected, focused: focused)
    }

    // MARK: - Cells

    private func shape(row: Int) -> (depth: Int, expander: OutlineView.Expander) {
        guard rows.indices.contains(row), let store = workspace.store else { return (0, .none) }
        let id = rows[row].id
        guard resultIDs == nil else { return (0, .none) }
        let expander: OutlineView.Expander = isExpandable(id, in: store)
            ? (expanded.contains(id) ? .expanded : .collapsed) : .none
        return (rows[row].depth, expander)
    }

    private func text(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), let store = workspace.store, let node = store.node(id: rows[row].id) else {
            return ""
        }
        switch column {
        case 0:
            // A match shows where it is.
            if resultIDs != nil, let parent = store.parent(of: node.id) {
                return node.name + "  ·  " + displayPath(parent.path)
            }
            return node.name
        case 1:
            return NeodiskFormatters.size(node.allocatedSize)
        case 2:
            let total = store.parent(of: node.id)?.allocatedSize ?? store.root.allocatedSize
            return NeodiskFormatters.percentage(part: node.allocatedSize, total: total) ?? ""
        case 3:
            return node.isDirectory ? node.descendantFileCount.formatted() : ""
        case 4:
            // An mtime of 0 (the epoch) means the filesystem doesn't track it.
            guard let date = node.lastModified, date.timeIntervalSince1970 > 0 else { return "" }
            return dateFormatter.string(from: date)
        default:
            return ""
        }
    }

    // MARK: - Keys

    private func handleKey(_ key: Int32) -> Bool {
        guard resultIDs == nil, let row = view.focusedRow, rows.indices.contains(row) else { return false }
        let id = rows[row].id
        switch key {
        case VK_RIGHT:
            if !expanded.contains(id) {
                setExpanded(row: row, true)
            } else if row + 1 < rows.count, rows[row + 1].depth > rows[row].depth {
                workspace.select(rows[row + 1].id)
            }
            return true
        case VK_LEFT:
            if expanded.contains(id) {
                setExpanded(row: row, false)
            } else if let parent = workspace.store?.parent(of: id)?.id, rowIndex[parent] != nil {
                workspace.select(parent)
            }
            return true
        default:
            return false
        }
    }
}
