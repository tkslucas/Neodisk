// Layout emits geometry and color tokens only; fills resolve in a separate `styled` pass so color
// changes never re-lay out. Stdlib only (no Foundation) so it stays Embedded-Swift-compatible for wasm.

public enum SunburstLayout {
    public nonisolated static let centerRadius: Double = 0.22
    /// Cosmetic only: hit-testing treats bands as glued, so hovering the gap still lands on an arc.
    public nonisolated static let ringGap: Double = 0.015
    /// In units of chart radius. Applied at draw time only, never to angles or hit-testing.
    public nonisolated static let angularSeam: Double = 0.008
    /// The synthetic free-space segment's id; exists in no tree store.
    public nonisolated static let freeSpaceSegmentID = "__sunburst-free-space__"
    /// The synthetic hidden-space segment's id; exists in no tree store.
    public nonisolated static let hiddenSpaceSegmentID = "__sunburst-hidden-space__"

    public typealias CancellationCheck = () throws -> Void

    /// Packages are opaque in the scan, so they behave as files until "Show Package Contents" splices them in.
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
        // Computed once and shared with the zoom remap, so drawn and hit-tested arcs agree.
        let metrics = SunburstRingMetrics(depthLimit: depthLimit)
        // The child-total floor keeps zero-byte children (one unit each) from overflowing into the synthetic
        // arcs.
        let freeBytes = max(freeSpaceBytes ?? 0, 0)
        let hiddenBytes = max(hiddenSpaceBytes ?? 0, 0)
        let childUnitTotal = visibleChildren.reduce(0.0) {
            $0 + Double(max($1.displayWeight(includingCloudOnly: includeCloudOnly), 1))
        }
        let rootWeight = root.displayWeight(includingCloudOnly: includeCloudOnly)
        let allocatedDenominator = max(Double(rootWeight), childUnitTotal)
        let denominator = allocatedDenominator + Double(freeBytes) + Double(hiddenBytes)
        // Anchored at the scan root so drilling preserves colors; free/hidden arcs never advance the cursor.
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

    /// For a folder on the outermost ring, where the layout stopped recursing and left no segments
    /// for the legend. Children take the full circle, as drilling in shows. O(children).
    public nonisolated static func ringSegments<Tree: SunburstTreeReading>(
        forFolder folderID: String,
        in treeStore: Tree,
        depth: Int,
        minimumAngle: Double = .pi / 90,
        expandedAggregateIDs: Set<String> = [],
        includeCloudOnly: Bool = false
    ) -> [SunburstSegment] {
        guard let folder = treeStore.node(id: folderID) else { return [] }
        let children = treeStore.children(of: folderID)
        guard !children.isEmpty else { return [] }

        let coordinate = folderID == treeStore.rootID
            ? (start: 0.0, span: 1.0, depth: 0)
            : colorCoordinate(for: folderID, in: treeStore, includeCloudOnly: includeCloudOnly)
                ?? (start: 0.0, span: 1.0, depth: 0)

        var ring: [SunburstSegment] = []
        // A depth budget of exactly one ring: `appendSegments` lays this one
        // out and its `depth + 1 < depthLimit` guard stops it from descending.
        try? appendSegments(
            in: treeStore,
            children: children,
            parentID: folderID,
            parentDenominator: Double(folder.displayWeight(includingCloudOnly: includeCloudOnly)),
            startAngle: 0,
            endAngle: .pi * 2,
            depth: depth,
            depthLimit: depth + 1,
            metrics: SunburstRingMetrics(depthLimit: depth + 1),
            colorStart: coordinate.start,
            colorSpan: coordinate.span,
            colorDepth: coordinate.depth + 1,
            minimumAngle: minimumAngle,
            expandedAggregateIDs: expandedAggregateIDs,
            includeCloudOnly: includeCloudOnly,
            cancellationCheck: {},
            into: &ring
        )
        return ring
    }

    // MARK: - Recursion

    private nonisolated static func appendSegments<Tree: SunburstTreeReading>(
        in treeStore: Tree,
        children: [Tree.Node],
        parentID: String,
        parentDenominator: Double,
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
        let effectiveChildTotal = children.reduce(0.0) { total, child in
            total + Double(max(child.displayWeight(includingCloudOnly: includeCloudOnly), 1))
        }
        let safeDenominator = max(parentDenominator, effectiveChildTotal)
        let totalAngle = endAngle - startAngle
        let grouped = try groupedChildren(
            children,
            parentID: parentID,
            denominator: safeDenominator,
            totalAngle: totalAngle,
            minimumAngle: minimumAngle,
            disableAggregation: expandedAggregateIDs.contains(parentID),
            includeCloudOnly: includeCloudOnly,
            cancellationCheck: cancellationCheck
        )

        var cursor = startAngle
        // Divided purely by size, no free/hidden slack. Every entry advances the cursor, gray files too,
        // so a large file shifts the hues of everything after it.
        var colorCursor = colorStart
        for entry in grouped {
            try cancellationCheck()
            let proportion = entry.weight / Double(safeDenominator)
            let segmentEnd = min(endAngle, cursor + (totalAngle * proportion))
            let entryColorSpan = colorSpan * (entry.weight / Double(effectiveChildTotal))
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
                    parentDenominator: Double(node.displayWeight(includingCloudOnly: includeCloudOnly)),
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
        denominator: Double,
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
        var groupedWeight = 0.0

        for child in children {
            try cancellationCheck()
            let size = max(child.displayWeight(includingCloudOnly: includeCloudOnly), 1)
            let angle = totalAngle * (Double(size) / Double(max(denominator, 1)))
            if angle < minimumAngle {
                groupedNodes.append(child)
                groupedSize = clampedSum(groupedSize, size)
                groupedWeight += Double(size)
            } else {
                visible.append(GroupEntry(node: child, includeCloudOnly: includeCloudOnly))
            }
        }

        if groupedNodes.count > 1 {
            let itemCount = groupedNodes.reduce(0) {
                clampedSum($0, $1.isDirectory ? max($1.descendantFileCount, 1) : 1)
            }
            // `children` is non-empty here; `?? ""` only avoids a Foundation UUID fallback that never runs.
            let aggregateID = "aggregate-\(children.first?.id ?? "")"
            visible.append(GroupEntry(
                id: aggregateID,
                nodeID: nil,
                label: "Smaller Items",
                totalSize: groupedSize,
                weight: groupedWeight,
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

    /// Same subdivision as the layout's color cursor, so colors outside a layout pass agree with segments.
    /// O(depth × siblings); nil for unknown nodes.
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
            var total = 0.0
            var before = 0.0
            var childUnit = 0.0
            var found = false
            for sibling in treeStore.children(of: parent.id) {
                let unit = Double(max(sibling.displayWeight(includingCloudOnly: includeCloudOnly), 1))
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

    /// Geometry uses floating-point weights so saturated byte totals retain
    /// their proportions; display sizes and item counts still saturate safely.
    private nonisolated static func clampedSum<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private nonisolated struct GroupEntry<Node: SunburstNode> {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let weight: Double
        let isAggregate: Bool
        let isDataless: Bool
        let node: Node?
        let itemCount: Int

        init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            weight: Double? = nil,
            isAggregate: Bool,
            isDataless: Bool = false,
            node: Node?,
            itemCount: Int
        ) {
            self.id = id
            self.nodeID = nodeID
            self.label = label
            self.totalSize = totalSize
            self.weight = weight ?? Double(totalSize)
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
