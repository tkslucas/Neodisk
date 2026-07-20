//
//  SunburstLayout.swift
//  SunburstCore
//
//  Sunburst ring layout and grouping. Adapted to represent
//  volume free/hidden space as synthetic top-ring segments. Layout emits
//  geometry + color tokens only — final fills resolve in a separate `styled`
//  pass (kept in NeodiskUI, which knows the app's palettes), so color changes
//  never re-lay the chart out.
//
//  Pure and generic over `SunburstTreeReading`: no SwiftUI, no NeodiskKit,
//  no Foundation — stdlib only, so it stays Embedded-Swift-compatible for the
//  wasm build. Display strings for the synthetic arcs are passed in by the
//  caller (NeodiskUI localizes them) rather than resolved via NSLocalizedString.
//

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
        includeCloudOnly: Bool = false,
        freeSpaceLabel: String = "Free Space",
        hiddenSpaceLabel: String = "Hidden Space",
        cancellationCheck: CancellationCheck
    ) throws -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        // Ring radii — bands taper with depth (deeper rings thinner). Computed
        // once here and threaded through the recursion; the zoom remap bands
        // through the same metrics, so drawn and hit-tested arcs agree.
        let metrics = SunburstRingMetrics(depthLimit: depthLimit)
        // Free and hidden space join the root denominator so the allocated
        // arcs shrink to make room; the child total floor keeps zero-byte
        // children (each counted as at least one unit) from overflowing into
        // the synthetic arcs.
        let freeBytes = max(freeSpaceBytes ?? 0, 0)
        let hiddenBytes = max(hiddenSpaceBytes ?? 0, 0)
        let childUnitTotal = visibleChildren.reduce(Int64(0)) {
            $0 + max($1.displayWeight(includingCloudOnly: includeCloudOnly), 1)
        }
        let rootWeight = root.displayWeight(includingCloudOnly: includeCloudOnly)
        let allocatedDenominator = max(max(rootWeight, Int64(visibleChildren.count)), childUnitTotal)
        let denominator = allocatedDenominator + freeBytes + hiddenBytes
        // The color coordinate is anchored at the scan root even when the
        // chart is drilled in, so drilling preserves every color. The
        // synthetic free/hidden arcs are not tree nodes and never advance
        // the color cursor: allocated data always spans the full hue wheel.
        let rootCoordinate = rootID == treeStore.rootID
            ? (start: 0.0, span: 1.0, depth: 0)
            : colorCoordinate(for: rootID, in: treeStore, includeCloudOnly: includeCloudOnly)
                ?? (start: 0.0, span: 1.0, depth: 0)

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
            metrics: metrics,
            colorStart: rootCoordinate.start,
            colorSpan: rootCoordinate.span,
            colorDepth: rootCoordinate.depth + 1,
            minimumAngle: minimumAngle,
            expandedAggregateIDs: expandedAggregateIDs,
            includeCloudOnly: includeCloudOnly,
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
                label: hiddenSpaceLabel,
                startAngle: .pi * 2 - freeAngle - hiddenAngle,
                endAngle: .pi * 2 - freeAngle,
                innerRadius: metrics.innerRadius(depth: 0),
                outerRadius: metrics.drawnOuterRadius(depth: 0),
                depth: 0,
                colorToken: SunburstColorToken(midpoint: 0, depth: 0, role: .hiddenSpace),
                totalSize: hiddenBytes,
                isAggregate: false
            ))
        }
        if freeBytes > 0 {
            result.append(SunburstSegment(
                id: freeSpaceSegmentID,
                nodeID: nil,
                label: freeSpaceLabel,
                startAngle: .pi * 2 - freeAngle,
                endAngle: .pi * 2,
                innerRadius: metrics.innerRadius(depth: 0),
                outerRadius: metrics.drawnOuterRadius(depth: 0),
                depth: 0,
                colorToken: SunburstColorToken(midpoint: 0, depth: 0, role: .freeSpace),
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
        metrics: SunburstRingMetrics,
        colorStart: Double,
        colorSpan: Double,
        colorDepth: Int,
        minimumAngle: Double,
        expandedAggregateIDs: Set<String>,
        includeCloudOnly: Bool,
        cancellationCheck: CancellationCheck,
        into segments: inout [SunburstSegment]
    ) throws {
        guard depth < depthLimit else { return }

        try cancellationCheck()
        let effectiveChildTotal = children.reduce(Int64(0)) { total, child in
            total + max(child.displayWeight(includingCloudOnly: includeCloudOnly), 1)
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
            includeCloudOnly: includeCloudOnly,
            cancellationCheck: cancellationCheck
        )

        var cursor = startAngle
        // The parent's color interval divides among the children purely by
        // size (no free/hidden slack — the hue wheel always covers the
        // data). Every entry advances the color cursor — gray files and
        // aggregates too — so a large file shifts the hues of everything
        // after it; grouped entries sum to the children they pool.
        var colorCursor = colorStart
        for entry in grouped {
            try cancellationCheck()
            let proportion = Double(entry.totalSize) / Double(safeDenominator)
            let segmentEnd = cursor + (totalAngle * proportion)
            let entryColorSpan = colorSpan * (Double(entry.totalSize) / Double(effectiveChildTotal))
            let colorToken = SunburstColorToken(
                midpoint: colorCursor + entryColorSpan / 2,
                depth: colorDepth,
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
                innerRadius: metrics.innerRadius(depth: depth),
                outerRadius: metrics.drawnOuterRadius(depth: depth),
                depth: depth,
                colorToken: colorToken,
                totalSize: entry.totalSize,
                isAggregate: entry.isAggregate,
                isDataless: entry.isDataless,
                parentFolderID: entry.isAggregate ? parentID : nil,
                itemCount: entry.itemCount
            )
            segments.append(segment)

            if let node = entry.node,
               depth + 1 < depthLimit,
               node.isDirectory,
               node.displayWeight(includingCloudOnly: includeCloudOnly) > 0 {
                let childNodes = try treeStore.children(of: node.id, cancellationCheck: cancellationCheck)
                guard !childNodes.isEmpty else {
                    cursor = segmentEnd
                    continue
                }

                try appendSegments(
                    in: treeStore,
                    children: childNodes,
                    parentID: node.id,
                    parentDenominator: node.displayWeight(includingCloudOnly: includeCloudOnly),
                    startAngle: cursor,
                    endAngle: segmentEnd,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    metrics: metrics,
                    colorStart: colorCursor,
                    colorSpan: entryColorSpan,
                    colorDepth: colorDepth + 1,
                    minimumAngle: minimumAngle,
                    expandedAggregateIDs: expandedAggregateIDs,
                    includeCloudOnly: includeCloudOnly,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }

            cursor = segmentEnd
            colorCursor += entryColorSpan
        }
    }

    private nonisolated static func groupedChildren<Node: SunburstNode>(
        _ children: [Node],
        parentID: String,
        denominator: Int64,
        totalAngle: Double,
        minimumAngle: Double,
        disableAggregation: Bool,
        includeCloudOnly: Bool,
        cancellationCheck: CancellationCheck
    ) throws -> [GroupEntry<Node>] {
        guard children.count > 1, !disableAggregation else {
            return children.map { GroupEntry(node: $0, includeCloudOnly: includeCloudOnly) }
        }

        var visible: [GroupEntry<Node>] = []
        var groupedNodes: [Node] = []
        var groupedSize: Int64 = 0

        for child in children {
            try cancellationCheck()
            let size = max(child.displayWeight(includingCloudOnly: includeCloudOnly), 1)
            let angle = totalAngle * (Double(size) / Double(max(denominator, 1)))
            if angle < minimumAngle {
                groupedNodes.append(child)
                groupedSize += size
            } else {
                visible.append(GroupEntry(node: child, includeCloudOnly: includeCloudOnly))
            }
        }

        if groupedNodes.count > 1 {
            let itemCount = groupedNodes.reduce(0) {
                $0 + ($1.isDirectory ? max($1.descendantFileCount, 1) : 1)
            }
            // `children` is non-empty here (guarded above), so `first` always
            // resolves; the `?? ""` only satisfies the optional and avoids a
            // Foundation UUID fallback that never runs.
            let aggregateID = "aggregate-\(children.first?.id ?? "")"
            visible.append(GroupEntry(
                id: aggregateID,
                nodeID: nil,
                label: "Smaller Items",
                totalSize: groupedSize,
                isAggregate: true,
                node: nil,
                itemCount: itemCount
            ))
        } else if let onlyGrouped = groupedNodes.first {
            visible.append(GroupEntry(node: onlyGrouped, includeCloudOnly: includeCloudOnly))
        }

        return visible
    }

    // MARK: - Color coordinate

    /// A node's global color coordinate: the start and span of its size
    /// interval and its depth, all relative to the scan root. This is the
    /// same subdivision the layout's color cursor performs — each level
    /// splits the parent's interval among the size-sorted siblings by
    /// weight — so call sites that color nodes outside a layout pass (the
    /// treemap's drilled scenes, the status-bar swatch, the legend) agree
    /// with rendered segments. O(depth × siblings); nil for unknown nodes.
    public nonisolated static func colorCoordinate(
        for nodeID: String,
        in treeStore: some SunburstTreeReading,
        includeCloudOnly: Bool = false
    ) -> (start: Double, span: Double, depth: Int)? {
        let chain = treeStore.path(to: nodeID)
        guard !chain.isEmpty else { return nil }

        var start = 0.0
        var span = 1.0
        var depth = 0
        for (parent, child) in zip(chain, chain.dropFirst()) {
            var total: Int64 = 0
            var before: Int64 = 0
            var childUnit: Int64 = 0
            var found = false
            for sibling in treeStore.children(of: parent.id) {
                let unit = max(sibling.displayWeight(includingCloudOnly: includeCloudOnly), 1)
                total += unit
                if sibling.id == child.id {
                    childUnit = unit
                    found = true
                } else if !found {
                    before += unit
                }
            }
            guard found, total > 0 else { return nil }
            start += span * (Double(before) / Double(total))
            span *= Double(childUnit) / Double(total)
            depth += 1
        }
        return (start, span, depth)
    }

    private nonisolated struct GroupEntry<Node: SunburstNode> {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let isDataless: Bool
        let node: Node?
        let itemCount: Int

        init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            isAggregate: Bool,
            isDataless: Bool = false,
            node: Node?,
            itemCount: Int
        ) {
            self.id = id
            self.nodeID = nodeID
            self.label = label
            self.totalSize = totalSize
            self.isAggregate = isAggregate
            self.isDataless = isDataless
            self.node = node
            self.itemCount = itemCount
        }

        init(node: Node, includeCloudOnly: Bool) {
            self.init(
                id: node.id,
                nodeID: node.id,
                label: node.name,
                totalSize: max(node.displayWeight(includingCloudOnly: includeCloudOnly), 1),
                isAggregate: false,
                // A dataless file, or a directory whose bytes are all in the
                // cloud (no local content) — the dashed cloud-only arc.
                isDataless: node.isDataless
                    || (node.cloudOnlyLogicalSize > 0 && node.allocatedSize == 0),
                node: node,
                itemCount: 0
            )
        }
    }
}
