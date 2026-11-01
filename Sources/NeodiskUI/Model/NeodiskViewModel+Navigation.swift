// Navigation verbs over the model's selection and zoom state; the stored state stays in NeodiskViewModel.swift.

import AppKit
import Foundation
import NeodiskKit
import NeodiskAppModel

extension NeodiskViewModel {
    // MARK: - Selection & zoom

    /// A plain click: just this item, or nothing.
    func select(_ nodeID: String?) {
        selection.replace(with: nodeID)  // its didSet widens the map if the node is off-screen
        if let nodeID {
            revealInOutline(nodeID)
            // With duplicate results on screen, selecting a copy drills into its group; a non-duplicate steps
            // out.
            if analysisTab == .duplicates {
                duplicates.handleSelection(of: nodeID)
            }
        }
    }

    /// The rows a user picked in a list. An extending gesture keeps what the list doesn't show; the primary is
    /// revealed in the outline like a plain selection.
    func select(fromList list: ListSelection, listShows: (String) -> Bool) {
        selection.applyList(
            selected: list.ids, primary: list.primary, extending: list.extending, listShows: listShows
        )
        if let primaryID = selection.primaryID { revealInOutline(primaryID) }
    }

    /// ⌘-click in a map: the item joins as the primary, or leaves.
    func toggleSelection(_ nodeID: String) {
        selection.toggle(nodeID)
        if selection.primaryID == nodeID { revealInOutline(nodeID) }
    }

    /// ⇧-arrow in a map: the item joins as the primary.
    func extendSelection(to nodeID: String) {
        selection.add(nodeID)
        revealInOutline(nodeID)
    }

    /// An arrow key in a map, from the primary item: only the target stays selected, or ⇧ adds it.
    func moveSelectionInMap(
        _ move: TreeKeyboardNav.Move, extending: Bool, includingCloudOnly: Bool = false,
        isRendered: ((String) -> Bool)?
    ) {
        guard let store, let rootID = effectiveRootID else { return }
        switch TreeKeyboardNav.target(
            from: selectedNodeID, move: move, rootID: rootID, store: store,
            includingCloudOnly: includingCloudOnly, isRendered: isRendered
        ) {
        case .select(let id)?:
            if extending { extendSelection(to: id) } else { select(id) }
        case .drillOut(let folderID)? where !extending:
            drillOut()
            select(folderID)
        default:
            NSSound.beep()
        }
    }

    /// Select All in a map: everything the map is rooted at shows, one level down.
    func selectAllInMap() {
        guard let store, let rootID = effectiveRootID else { return }
        let children = store.children(of: rootID).filter {
            !$0.isSynthetic && $0.displayWeight(includingCloudOnly: showsCloudOnlyFiles) > 0
        }
        guard !children.isEmpty else {
            NSSound.beep()
            return
        }
        selection.replace(with: children.map(\.id), primary: children.first?.id)
    }

    /// Widens the root out to the lowest common ancestor; never narrows (drilling in stays ⌘↓).
    /// Internal because the caller, selection's didSet, lives in NeodiskViewModel.swift.
    func widenRootToShow(_ nodeID: String) {
        guard let store, let currentRootID = effectiveRootID,
              currentRootID != store.root.id,
              !store.isAncestor(currentRootID, of: nodeID) else { return }
        // Both paths start at the scan root; the last shared node is the LCA.
        var lca = store.root.id
        for (a, b) in zip(store.path(to: currentRootID), store.path(to: nodeID)) {
            if a.id != b.id { break }
            lca = a.id
        }
        zoomRootID = lca == store.root.id ? nil : lca
    }

    /// Expands every ancestor so the outline shows the selected row.
    func revealInOutline(_ nodeID: String, includingNode: Bool = false) {
        guard let store else { return }
        let path = store.path(to: nodeID)
        expandOutlineNodes((includingNode ? path[...] : path.dropLast()).map(\.id))
    }

    func zoomOut() {
        guard let store, let effectiveRootID,
              let parent = store.parent(of: effectiveRootID) else {
            zoomRootID = nil
            return
        }
        zoomRootID = parent.id == store.root.id ? nil : parent.id
    }

    /// Whether the map is drilled below the scan root — enablement for the
    /// Go menu's Enclosing Folder and Back to Scan Root items.
    var canDrillOut: Bool {
        guard let store, let effectiveRootID else { return false }
        return effectiveRootID != store.root.id
    }

    /// Go > Back to Scan Root: undo all drilling in one step.
    func zoomToRoot() {
        zoomRootID = nil
    }

    /// Drills into the selected folder or the file's folder, so ⌘↓ always makes progress. False makes the
    /// caller beep.
    @discardableResult
    func drillIntoSelection() -> Bool {
        guard let store, let node = selectedNode, let dir = selectionDrillTarget else { return false }
        // A summarized folder has no children yet: expand it in place first; a second ⌘↓ then drills in.
        if dir.isAutoSummarized {
            expandNodeContents(dir)
            return true
        }
        zoomRootID = dir.id == store.root.id ? nil : dir.id
        // When the user explicitly drilled into a folder, land the selection
        // on its largest child so arrow keys keep working inside. A multi-selection stays as it is.
        if node.isDirectory, !selection.isMultiple {
            selectLargestChild(of: dir.id, in: store)
        }
        return true
    }

    /// Enablement for Go > Zoom Into Selection: false where ⌘↓ would only beep.
    var canDrillIntoSelection: Bool { selectionDrillTarget != nil }

    /// The folder ⌘↓ drills into: the selected folder, or a selected file's folder. Nil when that's already the
    /// root or has nothing to render (empty folders, opaque packages like most apps).
    private var selectionDrillTarget: FileNodeRecord? {
        guard let store, let node = selectedNode else { return nil }
        let targetDir = node.isDirectory ? node : store.parent(of: node.id)
        guard let dir = targetDir, dir.isDirectory, dir.id != effectiveRootID else { return nil }
        if dir.isAutoSummarized { return canRefreshSubtree ? dir : nil }
        return store.children(of: dir.id).contains(where: { $0.allocatedSize > 0 }) ? dir : nil
    }

    /// Double-click in a file list, as in Finder: a folder opens, here by drilling the map into it (as a
    /// double-click on the flat treemap does); anything else, or a folder with nothing to show, opens.
    func activate(_ node: FileNodeRecord) {
        if node.isDirectory, let store, let effectiveRootID {
            if node.id == effectiveRootID || drillIn(to: node.id) || reRoot(to: node.id) { return }
            // A folder in another branch than the map's root (the list shows the whole scan).
            if store.children(of: node.id).contains(where: { $0.allocatedSize > 0 }) {
                zoomRootID = node.id == store.root.id ? nil : node.id
                return
            }
        }
        guard supportsFileActions(node) else { return }
        open(node)
    }

    /// Only drills out; the selection stays untouched. False lets the caller fall back to selecting the crumb.
    @discardableResult
    func reRoot(to nodeID: String) -> Bool {
        guard let store, let node = store.node(id: nodeID), node.isDirectory,
              let effectiveRootID, node.id != effectiveRootID,
              store.isAncestor(node.id, of: effectiveRootID) else { return false }
        zoomRootID = node.id == store.root.id ? nil : node.id
        return true
    }

    /// Keeps the selection if it stays inside the new root, else lands on the largest child like ⌘↓.
    /// False lets the caller fall back to selecting the crumb.
    @discardableResult
    func drillIn(to nodeID: String) -> Bool {
        guard let store, let node = store.node(id: nodeID), node.isDirectory,
              let effectiveRootID, node.id != effectiveRootID,
              store.isAncestor(effectiveRootID, of: node.id) else { return false }
        // A summarized folder has no children in the store yet: expand its real
        // contents instead of re-rooting into a blank subtree (mirrors ⌘↓).
        if node.isAutoSummarized {
            guard canRefreshSubtree else { return false }
            expandNodeContents(node)
            return true
        }
        // Childless folders (empty dirs, opaque packages) have nothing to render.
        guard store.children(of: node.id).contains(where: { $0.allocatedSize > 0 }) else {
            return false
        }
        zoomRootID = node.id == store.root.id ? nil : node.id
        // Otherwise land on the largest child so the outline and arrow keys stay oriented.
        let selectionStaysInside = selectedNodeID.map {
            $0 != node.id && store.isAncestor(node.id, of: $0)
        } ?? false
        if !selectionStaysInside, !selection.isMultiple {
            selectLargestChild(of: node.id, in: store)
        }
        return true
    }

    /// Keyboard drill-out (⌘↑): re-root the treemap one level up. Returns
    /// false (caller beeps) when already at the scan root.
    @discardableResult
    func drillOut() -> Bool {
        guard let store, let effectiveRootID, effectiveRootID != store.root.id else {
            return false
        }
        zoomOut()
        return true
    }

    /// Go > Back (⌘[): return the map to the root it showed before the last
    /// re-root. Returns false (caller beeps) when there is nowhere to go.
    @discardableResult
    func drillBack() -> Bool {
        stepDrillHistory { history, current, isValid in
            history.goBack(from: current, isValid: isValid)
        }
    }

    /// Go > Forward (⌘]): undo a Back.
    @discardableResult
    func drillForward() -> Bool {
        stepDrillHistory { history, current, isValid in
            history.goForward(from: current, isValid: isValid)
        }
    }

    private func stepDrillHistory(
        _ step: (inout DrillHistory, String, (String) -> Bool) -> String?
    ) -> Bool {
        guard let store, let current = effectiveRootID else { return false }
        // A root a rescan removed is skipped (and dropped) on the way.
        guard let target = step(&drillHistory, current, { store.node(id: $0)?.isDirectory == true }) else {
            return false
        }
        isSteppingDrillHistory = true
        zoomRootID = target == store.root.id ? nil : target
        isSteppingDrillHistory = false
        // Keep the selection when it is still inside the map; otherwise land
        // on the largest child, as drilling in does.
        if !selection.isMultiple, let selectedNodeID,
           selectedNodeID == target || !store.isAncestor(target, of: selectedNodeID) {
            selectLargestChild(of: target, in: store)
        }
        return true
    }

    /// So arrow keys keep working inside; shared by ⌘↓ and breadcrumb drill-in.
    private func selectLargestChild(of folderID: String, in store: FileTreeStore) {
        // Largest on disk first, ties by name: the list's and sunburst's order.
        if let largest = store.children(of: folderID).first(where: { $0.allocatedSize > 0 }) {
            select(largest.id)
        }
    }

    // MARK: - Outline rows

    struct OutlineRow: Identifiable {
        let node: FileNodeRecord
        let depth: Int
        let isExpandable: Bool
        /// This node's share of its parent's displayed weight (1 for the
        /// root row); drives the bottom table's percentage bar.
        let fractionOfParent: Double

        var id: String { node.id }
    }

    /// In diff mode siblings order by change magnitude, which outranks a header sort so the diff reads
    /// top-down. Otherwise `sortedBy` reorders siblings; nil keeps the store's size order.
    func visibleOutlineRows(sortedBy sort: OutlineSort? = nil) -> [OutlineRow] {
        outlineRowsSnapshot(sortedBy: sort).rows
    }

    /// Separate from `visibleOutlineRows` so selection-only calls can be proven to reuse a snapshot.
    func flattenVisibleOutlineRows(sortedBy sort: OutlineSort? = nil) -> [OutlineRow] {
        guard let store, let effectiveRootID,
              let root = store.node(id: effectiveRootID) else { return [] }

        let includeCloudOnly = showsCloudOnlyFiles
        var rows: [OutlineRow] = []
        var stack: [(node: FileNodeRecord, depth: Int, fraction: Double)] = [(root, 0, 1)]

        while let (node, depth, fraction) = stack.popLast() {
            let isExpandable = node.isDirectory && store.containsChildren(id: node.id)
            rows.append(OutlineRow(
                node: node, depth: depth, isExpandable: isExpandable, fractionOfParent: fraction
            ))

            if isExpandable, expandedNodeIDs.contains(node.id) {
                var children = store.children(of: node.id)
                if let baseline = diff.baseline {
                    children.sort {
                        baseline.sizeDelta(for: $0).magnitude > baseline.sizeDelta(for: $1).magnitude
                    }
                } else if let sort {
                    children.sort(by: sort.areInIncreasingOrder(includingCloudOnly: includeCloudOnly))
                }
                let parentWeight = Double(node.displayWeight(includingCloudOnly: includeCloudOnly))
                for child in children.reversed() {
                    let childWeight = Double(child.displayWeight(includingCloudOnly: includeCloudOnly))
                    stack.append((
                        child, depth + 1, parentWeight > 0 ? childWeight / parentWeight : 0
                    ))
                }
            }
        }
        return rows
    }

    func toggleExpansion(_ nodeID: String) {
        var expanded = expandedNodeIDs
        if expanded.remove(nodeID) == nil {
            expanded.insert(nodeID)
        }
        replaceExpandedOutlineNodes(with: expanded)
    }
}

extension OutlineSort {
    /// Ties fall back to descending size then name, so every sort is deterministic.
    func areInIncreasingOrder(
        includingCloudOnly: Bool
    ) -> (FileNodeRecord, FileNodeRecord) -> Bool {
        let field = field
        let ascending = ascending
        return { a, b in
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = a.name.localizedStandardCompare(b.name)
            case .size:
                let weightA = a.displayWeight(includingCloudOnly: includingCloudOnly)
                let weightB = b.displayWeight(includingCloudOnly: includingCloudOnly)
                comparison = weightA == weightB
                    ? .orderedSame
                    : (weightA < weightB ? .orderedAscending : .orderedDescending)
            case .files:
                comparison = a.descendantFileCount == b.descendantFileCount
                    ? .orderedSame
                    : (a.descendantFileCount < b.descendantFileCount
                        ? .orderedAscending : .orderedDescending)
            case .modified:
                // Unknown dates sort as oldest, so they gather at the
                // ascending end instead of interleaving.
                let dateA = a.lastModified ?? .distantPast
                let dateB = b.lastModified ?? .distantPast
                comparison = dateA == dateB
                    ? .orderedSame
                    : (dateA < dateB ? .orderedAscending : .orderedDescending)
            }
            if comparison != .orderedSame {
                return ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            let sizeA = a.displayWeight(includingCloudOnly: includingCloudOnly)
            let sizeB = b.displayWeight(includingCloudOnly: includingCloudOnly)
            if sizeA != sizeB { return sizeA > sizeB }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
