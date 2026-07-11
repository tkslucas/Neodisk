//
//  SunburstLayout.swift
//  SunburstCore
//
//  Sunburst ring layout and grouping. Ported from Radix; adapted to represent
//  volume free/hidden space as synthetic top-ring segments. Layout emits
//  geometry + color tokens only — final fills resolve in a separate `styled`
//  pass (kept in NeodiskUI, which knows the app's palettes), so color changes
//  never re-lay the chart out.
//
//  Pure and generic over `SunburstTreeReading`: no SwiftUI, no NeodiskKit.
//

import Foundation

public enum SunburstLayout {
    public nonisolated static let centerRadius: Double = 0.22
    /// Visual breathing room between rings: each arc is drawn this much
    /// short of its full ring band. Purely cosmetic — hit-testing treats
    /// the bands as glued (see SunburstHitTestIndex) so hovering the gap
    /// still lands on the arc it hangs off, never a dead zone.
    public nonisolated static let ringGap: Double = 0.015
    /// Background seam between neighbors within the same ring, as arc
    /// length in units of the chart radius — thinner than the radial ring
    /// gap. Applied at draw time (each edge insets half), never to angles
    /// or hit-testing, so layout math and hovering are unaffected.
    public nonisolated static let angularSeam: Double = 0.008
    /// The synthetic free-space segment's id; exists in no tree store.
    public nonisolated static let freeSpaceSegmentID = "__sunburst-free-space__"
    /// The synthetic hidden-space segment's id; exists in no tree store.
    public nonisolated static let hiddenSpaceSegmentID = "__sunburst-hidden-space__"

    public typealias CancellationCheck = () throws -> Void

    /// Whether the sunburst treats this node as a drillable folder. Packages
    /// (.app, .imovielibrary, …) are directories on disk, but the scan keeps
    /// them opaque, so the sunburst treats them as files: gray in branch
    /// mode, Quick Look on click, never a drill target. Once "Show Package
    /// Contents" splices a package's children into the store it behaves like
    /// any other folder.
    public nonisolated static func isSunburstFolder(
        _ node: some SunburstNode,
        in tree: some SunburstTreeReading
    ) -> Bool {
        node.isDirectory && (!node.isPackage || tree.containsChildren(id: node.id))
    }

    /// Layout only — geometry and color tokens, no resolved fills. NeodiskUI's
    /// `styled` pass fills these in; a demo can resolve branch fills directly.
    public nonisolated static func segments<Tree: SunburstTreeReading>(
        in treeStore: Tree,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90,
        freeSpaceBytes: Int64? = nil,
        hiddenSpaceBytes: Int64? = nil,
        expandedAggregateIDs: Set<String> = [],
        cancellationCheck: CancellationCheck
    ) throws -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let ringStart = centerRadius
        let ringWidth = (0.98 - ringStart) / Double(max(depthLimit, 1))
        // Free and hidden space join the root denominator so the allocated
        // arcs shrink to make room; the child total floor keeps zero-byte
        // children (each counted as at least one unit) from overflowing into
        // the synthetic arcs.
        let freeBytes = max(freeSpaceBytes ?? 0, 0)
        let hiddenBytes = max(hiddenSpaceBytes ?? 0, 0)
        let childUnitTotal = visibleChildren.reduce(Int64(0)) { $0 + max($1.allocatedSize, 1) }
        let allocatedDenominator = max(max(root.allocatedSize, Int64(visibleChildren.count)), childUnitTotal)
        let denominator = allocatedDenominator + freeBytes + hiddenBytes
        let colorBranchContext = ColorBranchContext(rootChildIDs: rootColorBranchIDs(in: treeStore))

        var result: [SunburstSegment] = []
        try appendSegments(
            in: treeStore,
            children: visibleChildren,
            parentID: root.id,
            parentDenominator: denominator,
            startAngle: 0,
            endAngle: .pi * 2,
            depth: 0,
            depthLimit: depthLimit,
            ringStart: ringStart,
            ringWidth: ringWidth,
            branchContext: nil,
            colorBranchContext: colorBranchContext,
            minimumAngle: minimumAngle,
            expandedAggregateIDs: expandedAggregateIDs,
            cancellationCheck: cancellationCheck,
            into: &result
        )

        // Trailing synthetic arcs on the top ring: allocated … hidden, free.
        let freeAngle = (.pi * 2) * (Double(freeBytes) / Double(denominator))
        if hiddenBytes > 0 {
            let hiddenAngle = (.pi * 2) * (Double(hiddenBytes) / Double(denominator))
            result.append(SunburstSegment(
                id: hiddenSpaceSegmentID,
                nodeID: nil,
                label: NSLocalizedString("Hidden Space", comment: "Sunburst hidden-space segment label"),
                startAngle: .pi * 2 - freeAngle - hiddenAngle,
                endAngle: .pi * 2 - freeAngle,
                innerRadius: ringStart,
                outerRadius: ringStart + ringWidth - ringGap,
                depth: 0,
                colorToken: .single(id: hiddenSpaceSegmentID, role: .hiddenSpace),
                totalSize: hiddenBytes,
                isAggregate: false
            ))
        }
        if freeBytes > 0 {
            result.append(SunburstSegment(
                id: freeSpaceSegmentID,
                nodeID: nil,
                label: NSLocalizedString("Free Space", comment: "Sunburst free-space segment label"),
                startAngle: .pi * 2 - freeAngle,
                endAngle: .pi * 2,
                innerRadius: ringStart,
                outerRadius: ringStart + ringWidth - ringGap,
                depth: 0,
                colorToken: .single(id: freeSpaceSegmentID, role: .freeSpace),
                totalSize: freeBytes,
                isAggregate: false
            ))
        }
        return result
    }

    // MARK: - Recursion

    private nonisolated static func appendSegments<Tree: SunburstTreeReading>(
        in treeStore: Tree,
        children: [Tree.Node],
        parentID: String,
        parentDenominator: Int64,
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: Double,
        ringWidth: Double,
        branchContext: ColorBranch?,
        colorBranchContext: ColorBranchContext,
        minimumAngle: Double,
        expandedAggregateIDs: Set<String>,
        cancellationCheck: CancellationCheck,
        into segments: inout [SunburstSegment]
    ) throws {
        guard depth < depthLimit else { return }

        try cancellationCheck()
        let effectiveChildTotal = children.reduce(Int64(0)) { total, child in
            total + max(child.allocatedSize, 1)
        }
        let safeDenominator = max(parentDenominator, effectiveChildTotal)
        let totalAngle = endAngle - startAngle
        let grouped = try groupedChildren(
            children,
            parentID: parentID,
            denominator: safeDenominator,
            totalAngle: totalAngle,
            minimumAngle: minimumAngle,
            // A clicked-open "Smaller Items" pool renders its children
            // individually, however thin (mirrors the treemap's
            // expandAggregate contract).
            disableAggregation: expandedAggregateIDs.contains(parentID),
            cancellationCheck: cancellationCheck
        )

        let siblingIndexes = colorableIndexes(for: grouped)
        let siblingCount = max(siblingIndexes.count, 1)
        var cursor = startAngle
        for entry in grouped {
            try cancellationCheck()
            let proportion = Double(entry.totalSize) / Double(safeDenominator)
            let segmentEnd = cursor + (totalAngle * proportion)
            let siblingIndex = siblingIndexes[entry.id] ?? 0
            let branch = branchContext ?? colorBranch(
                for: entry,
                in: treeStore,
                context: colorBranchContext,
                fallbackIndex: siblingIndex,
                fallbackCount: siblingCount
            )
            let colorToken = SunburstColorToken(
                branchID: branch.id,
                localID: entry.colorID,
                branchIndex: branch.index,
                branchCount: branch.count,
                siblingIndex: siblingIndex,
                siblingCount: siblingCount,
                depth: depth,
                role: entry.isAggregate
                    ? .aggregate
                    : ((entry.node.map { isSunburstFolder($0, in: treeStore) }) ?? true ? .normal : .file)
            )
            let segment = SunburstSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                label: entry.label,
                startAngle: cursor,
                endAngle: segmentEnd,
                innerRadius: ringStart + Double(depth) * ringWidth,
                outerRadius: ringStart + Double(depth + 1) * ringWidth - ringGap,
                depth: depth,
                colorToken: colorToken,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate,
                parentFolderID: entry.isAggregate ? parentID : nil,
                itemCount: entry.itemCount
            )
            segments.append(segment)

            if let node = entry.node,
               depth + 1 < depthLimit,
               node.isDirectory,
               node.allocatedSize > 0 {
                let childNodes = try treeStore.children(of: node.id, cancellationCheck: cancellationCheck)
                guard !childNodes.isEmpty else {
                    cursor = segmentEnd
                    continue
                }

                try appendSegments(
                    in: treeStore,
                    children: childNodes,
                    parentID: node.id,
                    parentDenominator: node.allocatedSize,
                    startAngle: cursor,
                    endAngle: segmentEnd,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    ringStart: ringStart,
                    ringWidth: ringWidth,
                    branchContext: branch,
                    colorBranchContext: colorBranchContext,
                    minimumAngle: minimumAngle,
                    expandedAggregateIDs: expandedAggregateIDs,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }

            cursor = segmentEnd
        }
    }

    private nonisolated static func groupedChildren<Node: SunburstNode>(
        _ children: [Node],
        parentID: String,
        denominator: Int64,
        totalAngle: Double,
        minimumAngle: Double,
        disableAggregation: Bool,
        cancellationCheck: CancellationCheck
    ) throws -> [GroupEntry<Node>] {
        guard children.count > 1, !disableAggregation else {
            return children.map { GroupEntry(node: $0) }
        }

        var visible: [GroupEntry<Node>] = []
        var groupedNodes: [Node] = []
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let size = max(child.allocatedSize, 1)
            let angle = totalAngle * (Double(size) / Double(max(denominator, 1)))
            if angle < minimumAngle {
                groupedNodes.append(child)
                groupedSize += size
            } else {
                visible.append(GroupEntry(node: child))
            }
        }

        if groupedNodes.count > 1 {
            let itemCount = groupedNodes.reduce(0) {
                $0 + ($1.isDirectory ? max($1.descendantFileCount, 1) : 1)
            }
            let aggregateID = "aggregate-\(children.first?.id ?? UUID().uuidString)"
            visible.append(GroupEntry(
                id: aggregateID,
                nodeID: nil,
                label: "Smaller Items",
                totalSize: groupedSize,
                isAggregate: true,
                colorID: aggregateID,
                node: nil,
                itemCount: itemCount
            ))
        } else if let onlyGrouped = groupedNodes.first {
            visible.append(GroupEntry(node: onlyGrouped))
        }

        return visible
    }

    // MARK: - Branch families

    private nonisolated static func colorBranch<Tree: SunburstTreeReading>(
        for entry: GroupEntry<Tree.Node>,
        in treeStore: Tree,
        context: ColorBranchContext,
        fallbackIndex: Int,
        fallbackCount: Int
    ) -> ColorBranch {
        guard let branchID = topLevelBranchID(for: entry.nodeID, in: treeStore) else {
            return ColorBranch(id: entry.colorID, index: fallbackIndex, count: fallbackCount)
        }

        guard let branch = context.branch(id: branchID) else {
            return ColorBranch(id: branchID, index: fallbackIndex, count: fallbackCount)
        }

        return branch
    }

    private nonisolated static func rootColorBranchIDs(in treeStore: some SunburstTreeReading) -> [String] {
        treeStore.children(of: treeStore.rootID).map(\.id)
    }

    /// The scan-root child a node descends from — the branch its hue family
    /// derives from. Stable across sibling reorders and drill-ins because it
    /// always walks up to the scan root, not the focused root.
    public nonisolated static func topLevelBranchID(
        for nodeID: String?,
        in treeStore: some SunburstTreeReading
    ) -> String? {
        guard let nodeID else { return nil }
        guard nodeID != treeStore.rootID else { return nodeID }

        var currentID = nodeID
        while let parent = treeStore.parent(of: currentID) {
            if parent.id == treeStore.rootID {
                return currentID
            }
            currentID = parent.id
        }

        return nodeID
    }

    private nonisolated static func colorableIndexes<Node: SunburstNode>(
        for entries: [GroupEntry<Node>]
    ) -> [String: Int] {
        var indexes: [String: Int] = [:]
        indexes.reserveCapacity(entries.count)

        for entry in entries where !entry.isAggregate {
            indexes[entry.id] = indexes.count
        }

        return indexes
    }

    private nonisolated struct ColorBranch {
        let id: String
        let index: Int
        let count: Int
    }

    private nonisolated struct ColorBranchContext {
        private let indexByID: [String: Int]
        private let count: Int

        nonisolated init(rootChildIDs: [String]) {
            var indexByID: [String: Int] = [:]
            indexByID.reserveCapacity(rootChildIDs.count)

            for id in rootChildIDs where indexByID[id] == nil {
                indexByID[id] = indexByID.count
            }

            self.indexByID = indexByID
            self.count = max(indexByID.count, 1)
        }

        nonisolated func branch(id: String) -> ColorBranch? {
            guard let index = indexByID[id] else { return nil }
            return ColorBranch(id: id, index: index, count: count)
        }
    }

    private nonisolated struct GroupEntry<Node: SunburstNode> {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let colorID: String
        let node: Node?
        let itemCount: Int

        init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            isAggregate: Bool,
            colorID: String,
            node: Node?,
            itemCount: Int
        ) {
            self.id = id
            self.nodeID = nodeID
            self.label = label
            self.totalSize = totalSize
            self.isAggregate = isAggregate
            self.colorID = colorID
            self.node = node
            self.itemCount = itemCount
        }

        init(node: Node) {
            self.init(
                id: node.id,
                nodeID: node.id,
                label: node.name,
                totalSize: max(node.allocatedSize, 1),
                isAggregate: false,
                colorID: node.id,
                node: node,
                itemCount: 0
            )
        }
    }
}
