//
//  NeodiskViewModel+Navigation.swift
//  Neodisk
//
//  Navigation verbs over the model's selection/zoom state: selection with
//  reveal, drill in/out and breadcrumb re-rooting, and the outline's
//  flattened row list. Stored state (selectedNodeID, zoomRootID,
//  expandedNodeIDs) stays in NeodiskViewModel.swift; this file only moves.
//

import Foundation
import NeodiskKit

extension NeodiskViewModel {
    // MARK: - Selection & zoom

    func select(_ nodeID: String?) {
        selectedNodeID = nodeID  // its didSet widens the map if the node is off-screen
        if let nodeID {
            revealInOutline(nodeID)
            // With duplicate results on screen, selecting a copy anywhere
            // (treemap, outline) drills into its group; selecting a
            // non-duplicate steps back out of an open group.
            if analysisTab == .duplicates {
                duplicates.handleSelection(of: nodeID)
            }
        }
    }

    /// Keeps a selection visible when the map is drilled in: if the node lands
    /// outside the current root, widen the root OUT to the lowest common
    /// ancestor of the current root and the node. Only ever drills out —
    /// selecting something on the far side of the tree never narrows the view
    /// (drilling in stays ⌘↓). No-op at the full map, or when the node is
    /// already inside the drilled subtree. Internal (not private) because the
    /// caller — selectedNodeID's didSet — lives in NeodiskViewModel.swift.
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

    /// Keyboard drill-in (⌘↓): re-root the treemap into the selected folder,
    /// or into the folder containing the selected file, so "zoom into where I
    /// am" always makes progress. Returns false (caller beeps) when there is
    /// nowhere deeper to go — no selection, or already rooted at the target.
    @discardableResult
    func drillIntoSelection() -> Bool {
        guard let store, let node = selectedNode else { return false }
        // A selected directory is drilled into; a selected file drills into
        // its containing folder.
        let targetDir = node.isDirectory ? node : store.parent(of: node.id)
        guard let dir = targetDir, dir.isDirectory, dir.id != effectiveRootID else {
            return false
        }
        // A summarized folder has no children in the store yet: expand its
        // real contents (async scan + splice) instead of drilling into a blank
        // subtree. It populates in place; a second ⌘↓ then drills in normally.
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

    /// Breadcrumb navigation: re-root the treemap OUT to an ancestor folder.
    /// Only drills out — the target must be strictly above the current map
    /// root; drilling in stays keyboard-only (⌘↓). The selection is left
    /// untouched (it stays a descendant of the wider root). Returns false when
    /// the crumb isn't an out target, so the caller can fall back to selecting.
    @discardableResult
    func reRoot(to nodeID: String) -> Bool {
        guard let store, let node = store.node(id: nodeID), node.isDirectory,
              let effectiveRootID, node.id != effectiveRootID,
              store.isAncestor(node.id, of: effectiveRootID) else { return false }
        zoomRootID = node.id == store.root.id ? nil : node.id
        return true
    }

    /// Breadcrumb navigation: re-root the treemap IN to a descendant folder —
    /// the symmetric partner of `reRoot`. The target must sit strictly below
    /// the current map root (a crumb between the root and the selection). The
    /// selection is preserved when it stays inside the new root; otherwise it
    /// lands on the folder's largest child, matching ⌘↓. Returns false when the
    /// crumb isn't an in target, so the caller can fall back to selecting.
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
        // Keep the selection if it stays a descendant of the new root; otherwise
        // (the crumb was the selection itself, or nothing is selected) land on
        // the largest child so the outline and arrow keys stay oriented.
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



    /// Lands the selection on the folder's largest renderable child so arrow
    /// keys keep working inside — shared by ⌘↓ drill-in and breadcrumb
    /// drill-in.
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

    /// Depth-first flattening of the expanded portion of the tree. In diff
    /// mode, siblings order by how much they changed since the baseline
    /// (largest magnitude first, growth or shrinkage alike) — that ordering
    /// outranks a header sort so the diff reads top-down in both outline
    /// layouts. Otherwise `sortedBy` (the bottom table's header sort)
    /// reorders siblings; nil keeps the store's size order.
    func visibleOutlineRows(sortedBy sort: OutlineSort? = nil) -> [OutlineRow] {
        outlineRowsSnapshot(sortedBy: sort).rows
    }

    /// The structural cache's only flattening entry point. Kept separate
    /// from `visibleOutlineRows` so selection-only calls can be proven to
    /// reuse an existing snapshot.
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
    /// Sibling comparator for the flattened outline. Ties fall back to
    /// descending size then name, so every sort stays deterministic and the
    /// familiar biggest-first order shows through equal keys.
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
