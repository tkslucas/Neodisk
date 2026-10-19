// Navigation verbs over the model's selection and zoom state; the stored state stays in NeodiskViewModel.swift.

import Foundation
import NeodiskKit
import NeodiskAppModel

extension NeodiskViewModel {
    // MARK: - Selection & zoom

    func select(_ nodeID: String?) {
        selectedNodeID = nodeID  // its didSet widens the map if the node is off-screen
        if let nodeID {
            revealInOutline(nodeID)
            // With duplicate results on screen, selecting a copy drills into its group; a non-duplicate steps
            // out.
            if analysisTab == .duplicates {
                duplicates.handleSelection(of: nodeID)
            }
        }
    }

    /// Widens the root out to the lowest common ancestor; never narrows (drilling in stays ⌘↓).
    /// Internal because the caller, selectedNodeID's didSet, lives in NeodiskViewModel.swift.
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
        guard let store, let node = selectedNode else { return false }
        // A selected directory is drilled into; a selected file drills into
        // its containing folder.
        let targetDir = node.isDirectory ? node : store.parent(of: node.id)
        guard let dir = targetDir, dir.isDirectory, dir.id != effectiveRootID else {
            return false
        }
        // A summarized folder has no children yet: expand it in place first; a second ⌘↓ then drills in.
        if dir.isAutoSummarized {
            guard canRefreshSubtree else { return false }
            expandNodeContents(dir)
            return true
        }
        // Other childless folders (empty dirs, opaque packages) have nothing
        // to render — don't re-root into a blank map.
        guard store.children(of: dir.id).contains(where: { $0.allocatedSize > 0 }) else {
            return false
        }
        zoomRootID = dir.id == store.root.id ? nil : dir.id
        // When the user explicitly drilled into a folder, land the selection
        // on its largest child so arrow keys keep working inside.
        if node.isDirectory {
            selectLargestChild(of: dir.id, in: store)
        }
        return true
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
        if !selectionStaysInside {
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
        if let selectedNodeID, selectedNodeID == target || !store.isAncestor(target, of: selectedNodeID) {
            selectLargestChild(of: target, in: store)
        }
        return true
    }

    /// So arrow keys keep working inside; shared by ⌘↓ and breadcrumb drill-in.
    private func selectLargestChild(of folderID: String, in store: FileTreeStore) {
        let children = store.children(of: folderID).filter { $0.allocatedSize > 0 }
        if let largest = children.max(by: { $0.allocatedSize < $1.allocatedSize }) {
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
