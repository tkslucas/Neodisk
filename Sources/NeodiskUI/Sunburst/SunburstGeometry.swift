//
//  SunburstGeometry.swift
//  Neodisk
//
//  Sunburst ring layout, arc path construction, and hit testing. Ported from
//  Radix (Lucas's other disk analyzer); adapted to resolve each segment's
//  final fill color at layout time from the active analysis tab's color mode
//  (branch hues on Largest, kind/age colors elsewhere) and to represent
//  volume free space as one synthetic top-ring segment.
//

import SwiftUI
import NeodiskKit

/// How sunburst segments are colored, derived from the active analysis tab:
/// Radix's branch-hue algorithm on Largest (folders colored, files gray,
/// colorblind palette honored), the treemap's kind/age semantics on the
/// other tabs. Every mode resolves its final fill (including highlight
/// dimming) at layout time into `SunburstSegment.fillRGB`; the styler's
/// token fallback only covers segments without a node.
struct SunburstColorStyle: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Radix branch hues — stable per scan-root branch (Largest tab).
        case branch
        /// Kind catalog colors, directories neutral (Kinds/Duplicates tabs).
        case kind
        /// Modification-age ramp against the scan date (Age tab).
        case age(referenceDate: Date)
    }

    var mode: Mode = .branch
    var catalog: FileKindCatalog = .empty
    var highlight: TreemapHighlight?
    var palette: VizPalette = .standard

    static func == (lhs: SunburstColorStyle, rhs: SunburstColorStyle) -> Bool {
        lhs.mode == rhs.mode
            && lhs.catalog.buildID == rhs.catalog.buildID
            && lhs.highlight == rhs.highlight
            && lhs.palette == rhs.palette
    }
}

struct SunburstSegment: Identifiable, Hashable, Sendable {
    let id: String
    /// The represented tree node; nil for aggregate and free-space segments.
    let nodeID: String?
    let label: String
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let depth: Int
    let colorToken: SunburstColorToken
    /// Fill resolved at layout time (kind/age modes, highlight dimming
    /// applied); nil in branch mode, where the color resolver derives the
    /// fill from `colorToken`.
    let fillRGB: SIMD3<Float>?
    let totalSize: Int64
    let isAggregate: Bool
    /// For aggregate segments: the folder whose small children pooled here,
    /// so hover can report "N smaller items in <folder>".
    let parentFolderID: String?
    /// For aggregate segments: how many items pooled (descendant-counted,
    /// matching the treemap's aggregate cells).
    let itemCount: Int

    init(
        id: String,
        nodeID: String?,
        label: String,
        startAngle: Angle,
        endAngle: Angle,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        depth: Int,
        colorToken: SunburstColorToken,
        fillRGB: SIMD3<Float>? = nil,
        totalSize: Int64,
        isAggregate: Bool,
        parentFolderID: String? = nil,
        itemCount: Int = 0
    ) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.depth = depth
        self.colorToken = colorToken
        self.fillRGB = fillRGB
        self.totalSize = totalSize
        self.isAggregate = isAggregate
        self.parentFolderID = parentFolderID
        self.itemCount = itemCount
    }

    var isFreeSpace: Bool {
        colorToken.role == .freeSpace
    }
}

enum SunburstLayout {
    nonisolated static let centerRadius: CGFloat = 0.22
    /// The synthetic free-space segment's id; exists in no tree store.
    nonisolated static let freeSpaceSegmentID = "__sunburst-free-space__"

    typealias CancellationCheck = () throws -> Void

    nonisolated static func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90,
        style: SunburstColorStyle = SunburstColorStyle(),
        freeSpaceBytes: Int64? = nil
    ) -> [SunburstSegment] {
        (try? segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            minimumAngle: minimumAngle,
            style: style,
            freeSpaceBytes: freeSpaceBytes,
            cancellationCheck: {}
        )) ?? []
    }

    nonisolated static func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90,
        style: SunburstColorStyle = SunburstColorStyle(),
        freeSpaceBytes: Int64? = nil,
        cancellationCheck: CancellationCheck
    ) throws -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }
        try cancellationCheck()
        guard let root = treeStore.node(id: rootID) else { return [] }

        let rootChildren = try treeStore.children(of: root.id, cancellationCheck: cancellationCheck)
        let visibleChildren = rootChildren.isEmpty ? [root] : rootChildren
        let ringStart = centerRadius
        let ringWidth = (0.98 - ringStart) / CGFloat(max(depthLimit, 1))
        // Free space joins the root denominator so the allocated arcs shrink
        // to make room; the child total floor keeps zero-byte children (each
        // counted as at least one unit) from overflowing into the free arc.
        let freeBytes = max(freeSpaceBytes ?? 0, 0)
        let childUnitTotal = visibleChildren.reduce(Int64(0)) { $0 + max($1.allocatedSize, 1) }
        let allocatedDenominator = max(max(root.allocatedSize, Int64(visibleChildren.count)), childUnitTotal)
        let denominator = allocatedDenominator + freeBytes
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
            style: style,
            minimumAngle: minimumAngle,
            cancellationCheck: cancellationCheck,
            into: &result
        )

        if freeBytes > 0 {
            let freeAngle = (.pi * 2) * (Double(freeBytes) / Double(denominator))
            result.append(SunburstSegment(
                id: freeSpaceSegmentID,
                nodeID: nil,
                label: NSLocalizedString("Free Space", comment: "Sunburst free-space segment label"),
                startAngle: .radians(.pi * 2 - freeAngle),
                endAngle: .radians(.pi * 2),
                innerRadius: ringStart,
                outerRadius: ringStart + ringWidth - 0.015,
                depth: 0,
                colorToken: .single(id: freeSpaceSegmentID, role: .freeSpace),
                totalSize: freeBytes,
                isAggregate: false
            ))
        }
        return result
    }

    // MARK: - Recursion

    private nonisolated static func appendSegments(
        in treeStore: FileTreeStore,
        children: [FileNodeRecord],
        parentID: String,
        parentDenominator: Int64,
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: CGFloat,
        ringWidth: CGFloat,
        branchContext: ColorBranch?,
        colorBranchContext: ColorBranchContext,
        style: SunburstColorStyle,
        minimumAngle: Double,
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
                    : ((entry.node?.isDirectory ?? true) ? .normal : .file)
            )
            let segment = SunburstSegment(
                id: entry.id,
                nodeID: entry.nodeID,
                label: entry.label,
                startAngle: .radians(cursor),
                endAngle: .radians(segmentEnd),
                innerRadius: ringStart + CGFloat(depth) * ringWidth,
                outerRadius: ringStart + CGFloat(depth + 1) * ringWidth - 0.015,
                depth: depth,
                colorToken: colorToken,
                fillRGB: entry.node.flatMap { resolvedFillRGB(for: $0, token: colorToken, style: style) },
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
                    style: style,
                    minimumAngle: minimumAngle,
                    cancellationCheck: cancellationCheck,
                    into: &segments
                )
            }

            cursor = segmentEnd
        }
    }

    private nonisolated static func groupedChildren(
        _ children: [FileNodeRecord],
        parentID: String,
        denominator: Int64,
        totalAngle: Double,
        minimumAngle: Double,
        cancellationCheck: CancellationCheck
    ) throws -> [GroupEntry] {
        guard children.count > 1 else {
            return children.map { GroupEntry(node: $0) }
        }

        var visible: [GroupEntry] = []
        var groupedNodes: [FileNodeRecord] = []
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

    // MARK: - Fill resolution

    /// A node's final fill, resolved at layout time. Kind/age modes mirror
    /// the treemap: kind catalog colors (directories neutral), the age ramp,
    /// and `TreemapScene.dimmedRGB` for segments a highlight doesn't match.
    /// Branch mode resolves the token (branch hues honoring the palette —
    /// colorblind branches restrict to Okabe-Ito hues — and gray files).
    /// Internal (not private) so the legend list can resolve the same fill
    /// for nodes without a rendered segment (children of a max-depth folder).
    nonisolated static func resolvedFillRGB(
        for node: FileNodeRecord,
        token: SunburstColorToken,
        style: SunburstColorStyle
    ) -> SIMD3<Float>? {
        var rgb: SIMD3<Float>
        switch style.mode {
        case .branch:
            return SunburstColorResolver.rgb(for: token, palette: style.palette)
        case .kind:
            rgb = style.catalog.rgb(for: node)
        case .age(let referenceDate):
            if FileKindClassifier.isKindCountable(node) {
                rgb = style.palette.ageRGB(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
            } else {
                rgb = FileKindCatalog.directoryRGB
            }
        }
        if let highlight = style.highlight,
           !matches(node, highlight: highlight, mode: style.mode, catalog: style.catalog) {
            rgb = TreemapScene.dimmedRGB(rgb)
        }
        return rgb
    }

    /// Whether a node stays at full color under an active highlight — the
    /// same semantics as the treemap's: an age-bucket highlight needs the
    /// `.age` mode's reference date; with any other mode it matches nothing.
    private nonisolated static func matches(
        _ node: FileNodeRecord,
        highlight: TreemapHighlight,
        mode: SunburstColorStyle.Mode,
        catalog: FileKindCatalog
    ) -> Bool {
        switch highlight {
        case .kind(let kindID):
            return FileKindClassifier.kindID(for: node, mode: catalog.mode) == kindID
        case .ageBucket(let bucket):
            guard case .age(let referenceDate) = mode,
                  FileKindClassifier.isKindCountable(node) else { return false }
            return AgeBucket.bucket(for: node.lastModified, reference: referenceDate) == bucket
        case .nodes(let ids):
            return ids.contains(node.id)
        }
    }

    // MARK: - Branch families

    private nonisolated static func colorBranch(
        for entry: GroupEntry,
        in treeStore: FileTreeStore,
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

    private nonisolated static func rootColorBranchIDs(in treeStore: FileTreeStore) -> [String] {
        treeStore.children(of: treeStore.rootID).map(\.id)
    }

    /// The scan-root child a node descends from — the branch its hue family
    /// derives from. Stable across sibling reorders and drill-ins because it
    /// always walks up to the scan root, not the focused root.
    nonisolated static func topLevelBranchID(
        for nodeID: String?,
        in treeStore: FileTreeStore
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

    private nonisolated static func colorableIndexes(
        for entries: [GroupEntry]
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

    private nonisolated struct GroupEntry {
        let id: String
        let nodeID: String?
        let label: String
        let totalSize: Int64
        let isAggregate: Bool
        let colorID: String
        let node: FileNodeRecord?
        let itemCount: Int

        init(
            id: String,
            nodeID: String?,
            label: String,
            totalSize: Int64,
            isAggregate: Bool,
            colorID: String,
            node: FileNodeRecord?,
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

        init(node: FileNodeRecord) {
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

enum SunburstRenderer {
    nonisolated static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let innerRadius = maxRadius * segment.innerRadius
        let outerRadius = maxRadius * segment.outerRadius

        let start = segment.startAngle.radians - (.pi / 2)
        let end = segment.endAngle.radians - (.pi / 2)

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(end),
            endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

enum SunburstHitTester {
    nonisolated static func segment(
        at point: CGPoint,
        in size: CGSize,
        segments: [SunburstSegment]
    ) -> SunburstSegment? {
        SunburstHitTestIndex(segments: segments).segment(at: point, in: size)
    }
}

enum SunburstCenterHitTester {
    nonisolated static func contains(
        point: CGPoint,
        in size: CGSize,
        radius: CGFloat = SunburstLayout.centerRadius
    ) -> Bool {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0, radius > 0 else { return false }

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt((dx * dx) + (dy * dy))
        return (distance / maxRadius) < radius
    }
}

struct SunburstHitTestIndex: Sendable {
    private let rings: [Ring]

    nonisolated init(segments: [SunburstSegment]) {
        var ringSegmentsByDepth: [Int: [SunburstSegment]] = [:]
        for segment in segments {
            ringSegmentsByDepth[segment.depth, default: []].append(segment)
        }

        rings = ringSegmentsByDepth
            .map { depth, segments in
                Ring(depth: depth, segments: segments)
            }
            .sorted { $0.depth < $1.depth }
    }

    nonisolated func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        guard !rings.isEmpty else { return nil }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0 else { return nil }

        let distance = sqrt((dx * dx) + (dy * dy))
        let normalizedDistance = distance / maxRadius
        guard let ring = rings.first(where: { $0.contains(normalizedDistance) }) else {
            return nil
        }

        var radians = atan2(dy, dx) + (.pi / 2)
        if radians < 0 {
            radians += (.pi * 2)
        }

        return ring.segment(containing: radians)
    }

    private struct Ring: Sendable {
        let depth: Int
        let minInnerRadius: CGFloat
        let maxOuterRadius: CGFloat
        let segments: [SunburstSegment]

        nonisolated init(depth: Int, segments: [SunburstSegment]) {
            self.depth = depth
            self.segments = segments.sorted { lhs, rhs in
                lhs.startAngle.radians < rhs.startAngle.radians
            }

            var minInnerRadius = CGFloat.greatestFiniteMagnitude
            var maxOuterRadius: CGFloat = 0
            for segment in segments {
                minInnerRadius = min(minInnerRadius, segment.innerRadius)
                maxOuterRadius = max(maxOuterRadius, segment.outerRadius)
            }

            self.minInnerRadius = minInnerRadius == .greatestFiniteMagnitude ? 0 : minInnerRadius
            self.maxOuterRadius = maxOuterRadius
        }

        nonisolated func contains(_ normalizedDistance: CGFloat) -> Bool {
            normalizedDistance >= minInnerRadius && normalizedDistance <= maxOuterRadius
        }

        nonisolated func segment(containing radians: Double) -> SunburstSegment? {
            guard !segments.isEmpty else { return nil }

            var lowerBound = 0
            var upperBound = segments.count
            while lowerBound < upperBound {
                let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
                if segments[midpoint].startAngle.radians <= radians {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }

            let candidateIndex = max(lowerBound - 1, 0)
            let candidate = segments[candidateIndex]
            guard radians >= candidate.startAngle.radians,
                  radians <= candidate.endAngle.radians else {
                return nil
            }
            return candidate
        }
    }
}
