//
//  ScanTreeAssembler.swift
//  Neodisk
//

import Foundation

/// Phase 2 of a scan: turns the coordinator's dense phase-1 state (completed
/// directory scans keyed 0..<nextKey, plus each key's child keys) into the
/// contiguous `FileTreeStore` the app consumes.
///
/// Extracted from `ScanTraversal.assembleTree` so the assembly can be driven
/// and asserted in isolation (see `ScanTreeAssemblerTests`), and so the fast
/// numeric path can sit next to the verbatim `legacyAssemble` it is checked
/// against. The assembler never touches `ScanMetrics`, the event stream, or
/// the warning list directly — all of that is routed back to the scan task
/// through `Callbacks`, which are only ever invoked from that task (never from
/// a parallel section).
nonisolated enum ScanTreeAssembler {
    typealias CompletedDirScan = ScanEngine.CompletedDirScan
    typealias AssemblyChildReference = ScanTraversal.AssemblyChildReference
    typealias AggregateStatsAccumulator = ScanTraversal.AggregateStatsAccumulator

    /// Side effects the assembler hands back to the scan task. Each is called
    /// only on that task, in order, so they may freely touch scan-confined
    /// state. Defaults are no-ops so tests can drive assembly without wiring
    /// up progress/warning plumbing.
    struct Callbacks {
        /// Throws `CancellationError` to abort assembly at a safe point.
        var cancellationCheck: () throws -> Void = {}
        /// Reports finalization progress in [0, 1] as the reverse pass runs.
        var progress: (_ finalizationFraction: Double) -> Void = { _ in }
        /// Surfaces a duplicate-node warning discovered during flattening.
        var warning: (ScanWarning) -> Void = { _ in }
        /// Fires once per traversable directory as it is finalized, so the
        /// coordinator can advance its completed-item count.
        var directoryFinalized: () -> Void = {}

        init(
            cancellationCheck: @escaping () throws -> Void = {},
            progress: @escaping (_ finalizationFraction: Double) -> Void = { _ in },
            warning: @escaping (ScanWarning) -> Void = { _ in },
            directoryFinalized: @escaping () -> Void = {}
        ) {
            self.cancellationCheck = cancellationCheck
            self.progress = progress
            self.warning = warning
            self.directoryFinalized = directoryFinalized
        }
    }

    /// One finalized child of a directory. `leafIndex >= 0` points into the
    /// owning directory's `directLeafNodes` (`key` is that directory's key);
    /// `leafIndex == -1` is a keyed child materialized from `key`. A POD pair
    /// of `Int32`s so per-directory child ordering sorts 8-byte elements
    /// instead of the ~330-byte record tuples the legacy path moved.
    struct ChildRef {
        var key: Int32
        var leafIndex: Int32
    }

    /// The fast path: numeric bottom-up aggregation plus a single-pass
    /// preorder flatten, producing a `FileTreeStore` byte-identical to
    /// `legacyAssemble`. Directory totals are summed into flat numeric arrays
    /// (no intermediate `FileNodeRecord` construction), each directory's child
    /// list is ordered by the same comparator over `ChildRef`s, and every node
    /// is materialized exactly once.
    ///
    /// Duplicate node ids (impossible under phase-1's global path dedup, but a
    /// safety net) are caught by `NodeIDIndex.building`; on detection this
    /// forwards to `legacyAssemble`, which dedups and warns. Phase-1 state is
    /// never mutated here, so the fallback rerun starts clean.
    static func assemble(
        completedByKey: [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64],
        targetURL: URL,
        diagnostics: ScanDiagnosticsContext?,
        callbacks: Callbacks
    ) throws -> FileTreeStore {
        guard nextKey > 0 else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif

        // Step 1 — reverse numeric aggregation. Children have higher keys than
        // their parent, so one reverse pass resolves every child's totals
        // before its parent sums them. Replicates FileNodeRecord.directory's
        // field choices exactly, without building any records.
        let aggregateStart = ContinuousClock.now
        var allocated = [Int64](repeating: 0, count: nextKey)
        var logical = [Int64](repeating: 0, count: nextKey)
        var cloudOnly = [Int64](repeating: 0, count: nextKey)
        var descendantFiles = [Int](repeating: 0, count: nextKey)
        var subtreeAccessible = [Bool](repeating: true, count: nextKey)
        var resolved = [Bool](repeating: false, count: nextKey)
        var isTraversableDir = [Bool](repeating: false, count: nextKey)
        var sortName = [String](repeating: "", count: nextKey)
        var resolvedCount = 0
        var directLeafTotal = 0

        var processed = 0
        for key in (0..<nextKey).reversed() {
            if processed.isMultiple(of: 256) {
                try callbacks.cancellationCheck()
            }
            guard let completed = completedByKey[key] else { continue }
            processed += 1

            if completed.isTraversable {
                var a: Int64 = 0
                var l: Int64 = 0
                var c: Int64 = 0
                var files = 0
                var accessible = completed.metadata.isReadable
                for leaf in completed.directLeafNodes {
                    a = a.addingClamped(leaf.allocatedSize)
                    l = l.addingClamped(leaf.logicalSize)
                    c = c.addingClamped(leaf.cloudOnlyLogicalSize)
                    files += leaf.isDirectory
                        ? leaf.descendantFileCount
                        : (leaf.isSymbolicLink || leaf.isSynthetic ? 0 : 1)
                    accessible = accessible && leaf.isAccessible
                }
                for childKey in childrenKeysByKey[key] where resolved[childKey] {
                    a = a.addingClamped(allocated[childKey])
                    l = l.addingClamped(logical[childKey])
                    c = c.addingClamped(cloudOnly[childKey])
                    files += descendantFiles[childKey]
                    accessible = accessible && subtreeAccessible[childKey]
                }
                allocated[key] = a
                logical[key] = l
                cloudOnly[key] = c
                descendantFiles[key] = files
                subtreeAccessible[key] = accessible
                isTraversableDir[key] = true
                resolved[key] = true
                sortName[key] = ScanTarget.displayName(for: completed.url)
                resolvedCount += 1
                directLeafTotal += completed.directLeafNodes.count
                callbacks.directoryFinalized()
            } else if let node = completed.node {
                allocated[key] = node.allocatedSize
                logical[key] = node.logicalSize
                cloudOnly[key] = node.cloudOnlyLogicalSize
                descendantFiles[key] = node.isDirectory
                    ? node.descendantFileCount
                    : (node.isSymbolicLink || node.isSynthetic ? 0 : 1)
                subtreeAccessible[key] = node.isAccessible
                resolved[key] = true
                sortName[key] = node.name
                resolvedCount += 1
            }
        }
        ScanTiming.record("scan.assemble.aggregate", ContinuousClock.now - aggregateStart)

        guard resolved[0] else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }
        // Progress bands are weighted by measured phase cost on a clone-heavy
        // home dir (aggregate 0.5s, sort 2.9s, flatten 0.9s, index+hardlink
        // 0.2s, clone dedup 8.2s): the clone pass gets half the band so its
        // syscall storm no longer sits behind a frozen bar. Clone-light trees
        // jump through the unused band — forward jumps are fine, stalls are
        // not.
        callbacks.progress(0.1)

        // Step 2 — per-directory child ordering, in the legacy pre-sort order
        // (direct leaves in batch order, then keyed children in key order),
        // sorted by the same comparator. Identical input order + comparator +
        // sort algorithm reproduce the legacy permutation even on ties.
        //
        // Deliberately sequential: fanning the per-directory sorts across a
        // DispatchQueue.concurrentPerform was measured slower on the tie-heavy
        // benchmark (sort 877ms → 1068ms on 300k). The comparator's
        // `localizedStandardCompare` and the Swift String/record retain-release
        // it drives contend across cores, so more threads lose to atomic and
        // ICU-lock traffic. Sorting the small 8-byte `ChildRef`s (vs the
        // legacy ~330-byte record tuples) is the win that stands.
        let sortStart = ContinuousClock.now
        var childRefsByKey = [[ChildRef]](repeating: [], count: nextKey)
        for key in 0..<nextKey where isTraversableDir[key] {
            if key.isMultiple(of: 1_024) {
                try callbacks.cancellationCheck()
            }
            guard let completed = completedByKey[key] else { continue }
            let directLeaves = completed.directLeafNodes
            var refs: [ChildRef] = []
            refs.reserveCapacity(directLeaves.count + childrenKeysByKey[key].count)
            for leafIndex in 0..<directLeaves.count {
                refs.append(ChildRef(key: Int32(key), leafIndex: Int32(leafIndex)))
            }
            for childKey in childrenKeysByKey[key] where resolved[childKey] {
                refs.append(ChildRef(key: Int32(childKey), leafIndex: -1))
            }
            refs.sort { lhs, rhs in
                let lhsAllocated = lhs.leafIndex >= 0
                    ? directLeaves[Int(lhs.leafIndex)].allocatedSize
                    : allocated[Int(lhs.key)]
                let rhsAllocated = rhs.leafIndex >= 0
                    ? directLeaves[Int(rhs.leafIndex)].allocatedSize
                    : allocated[Int(rhs.key)]
                if lhsAllocated == rhsAllocated {
                    let lhsName = lhs.leafIndex >= 0
                        ? directLeaves[Int(lhs.leafIndex)].name
                        : sortName[Int(lhs.key)]
                    let rhsName = rhs.leafIndex >= 0
                        ? directLeaves[Int(rhs.leafIndex)].name
                        : sortName[Int(rhs.key)]
                    return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                }
                return lhsAllocated > rhsAllocated
            }
            childRefsByKey[key] = refs
        }
        ScanTiming.record("scan.assemble.sort", ContinuousClock.now - sortStart)
        callbacks.progress(0.35)

        // Step 3 — single-pass preorder flatten. Each node is materialized
        // exactly once: leaves are passed through, directories built via the
        // memberwise init from the step-1 aggregates.
        let flattenStart = ContinuousClock.now
        let estimatedNodeCount = resolvedCount + directLeafTotal
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        nodes.reserveCapacity(estimatedNodeCount)
        parentIndices.reserveCapacity(estimatedNodeCount)
        var aggregateStats = AggregateStatsAccumulator()
        let progressStride = max(estimatedNodeCount / 20, 1)
        var stack: [FlattenEntry] = [FlattenEntry(key: 0, leafIndex: -1, parent: -1)]
        while let entry = stack.popLast() {
            if nodes.count.isMultiple(of: 1_024) {
                try callbacks.cancellationCheck()
                if nodes.count.isMultiple(of: progressStride) {
                    let fraction = 0.35 + 0.1 * Double(nodes.count) / Double(max(estimatedNodeCount, 1))
                    callbacks.progress(min(fraction, 0.45))
                }
            }
            let record: FileNodeRecord
            let refs: [ChildRef]
            if entry.leafIndex >= 0 {
                record = completedByKey[Int(entry.key)]!.directLeafNodes[Int(entry.leafIndex)]
                refs = []
            } else {
                let key = Int(entry.key)
                let completed = completedByKey[key]!
                if isTraversableDir[key] {
                    record = FileNodeRecord(
                        id: completed.url.path,
                        path: completed.url.path,
                        name: sortName[key],
                        isDirectory: true,
                        isSymbolicLink: false,
                        allocatedSize: allocated[key],
                        logicalSize: logical[key],
                        descendantFileCount: descendantFiles[key],
                        lastModified: completed.metadata.lastModified,
                        fileIdentity: completed.metadata.fileIdentity,
                        linkCount: completed.metadata.linkCount,
                        isPackage: completed.metadata.isPackage,
                        isAccessible: subtreeAccessible[key],
                        isSelfAccessible: completed.metadata.isReadable,
                        isSynthetic: false,
                        isAutoSummarized: false,
                        cloudOnlyLogicalSize: cloudOnly[key]
                    )
                    refs = childRefsByKey[key]
                } else {
                    record = completed.node!
                    refs = []
                }
            }
            let index = Int32(nodes.count)
            nodes.append(record)
            parentIndices.append(entry.parent)
            aggregateStats.include(record, hasChildren: !refs.isEmpty)
            for ref in refs.reversed() {
                stack.append(FlattenEntry(key: ref.key, leafIndex: ref.leafIndex, parent: index))
            }
        }
        let (childStarts, initialChildSlots) = TreeStorage.childLayout(parentIndices: parentIndices)
        var childSlots = initialChildSlots
        ScanTiming.record("scan.assemble.flatten", ContinuousClock.now - flattenStart)

        // Step 4 — parallel id index build (also detects duplicate ids), then
        // the shared-block dedup passes. On a duplicate, hand off to the
        // verbatim legacy assembler.
        let indexStart = ContinuousClock.now
        guard let built = NodeIDIndex.building(from: nodes) else {
            return try legacyAssemble(
                completedByKey: completedByKey,
                childrenKeysByKey: childrenKeysByKey,
                nextKey: nextKey,
                hardLinkClaims: hardLinkClaims,
                minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID,
                targetURL: targetURL,
                diagnostics: diagnostics,
                callbacks: callbacks
            )
        }
        let indexByID = built.index
        ScanTiming.record("scan.assemble.index", ContinuousClock.now - indexStart)

        let dedupStart = ContinuousClock.now
        HardLinkDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            indexByID: indexByID,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
        let cloneStart = ContinuousClock.now
        ScanTiming.record("scan.assemble.dedup.hardlink", cloneStart - dedupStart)
        callbacks.progress(0.5)
        try CloneDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            indexByID: indexByID,
            cancellationCheck: callbacks.cancellationCheck,
            progress: { callbacks.progress(0.5 + 0.48 * $0) }
        )
        ScanTiming.record("scan.assemble.dedup.clone", ContinuousClock.now - cloneStart)
        ScanTiming.record("scan.assemble.dedup", ContinuousClock.now - dedupStart)

        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize",
            url: targetURL,
            startedAt: finalizationStart,
            itemCount: nodes.count
        )
        #endif

        guard let rootNode = nodes.first else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }
        callbacks.progress(1.0)

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: indexByID,
                nodeHashes: built.hashes
            ),
            rootID: rootNode.id,
            aggregateStats: aggregateStats.makeStats(root: rootNode)
        )
    }

    /// POD flatten-stack frame. A direct leaf carries its owning directory's
    /// key plus the index into that directory's `directLeafNodes`; a keyed
    /// node carries its own key and `leafIndex == -1`.
    private struct FlattenEntry {
        var key: Int32
        var leafIndex: Int32
        var parent: Int32
    }

    /// The pre-rework assembly, moved here verbatim. Retained as the
    /// correctness oracle for the numeric fast path and as its
    /// duplicate-id fallback: the fast path leaves phase-1 state untouched
    /// until it succeeds, so a rerun here starts from a clean slate.
    ///
    /// Consumes `completedByKey` so the large direct-leaf batches free
    /// progressively as the reverse pass drops each key.
    static func legacyAssemble(
        completedByKey: consuming [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64],
        targetURL: URL,
        diagnostics: ScanDiagnosticsContext?,
        callbacks: Callbacks
    ) throws -> FileTreeStore {
        var completedByKey = completedByKey

        let finalizationTotal = max(completedByKey.count, 1)
        let finalizationProgressInterval = 512
        var finalizedItems = 0
        var directLeafCount = 0
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var sortedChildReferencesByKey: [Int: [AssemblyChildReference]] = [:]
        resolvedNodeByKey.reserveCapacity(completedByKey.count)
        sortedChildReferencesByKey.reserveCapacity(completedByKey.count)
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif
        let aggregateStart = ContinuousClock.now
        var sortDuration: Duration = .zero
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try callbacks.cancellationCheck()
            }
            guard let completed = completedByKey[key] else { continue }
            // Drop the (possibly large) direct-leaf batch as soon as it is
            // consumed, matching the old dictionary's per-key removeValue.
            completedByKey[key] = nil
            finalizedItems += 1

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey[key]
                directLeafCount += completed.directLeafNodes.count
                var childPairs: [(reference: AssemblyChildReference, node: FileNodeRecord)] =
                    completed.directLeafNodes.map { (.direct($0), $0) }
                childPairs.reserveCapacity(childPairs.count + childKeys.count)
                for (offset, childKey) in childKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try callbacks.cancellationCheck()
                    }
                    if let childNode = resolvedNodeByKey[childKey] {
                        childPairs.append((.keyed(childKey), childNode))
                    }
                }
                if childPairs.count > 1 {
                    var seenIDs = Set<String>()
                    childPairs = childPairs.filter { seenIDs.insert($0.node.id).inserted }
                }
                let sortStart = ContinuousClock.now
                childPairs.sort { FileTreeStore.childDisplayOrder($0.node, $1.node) }
                sortDuration += ContinuousClock.now - sortStart
                try callbacks.cancellationCheck()
                let assembled = FileNodeRecord.directory(
                    id: completed.url.path,
                    url: completed.url,
                    name: ScanTarget.displayName(for: completed.url),
                    children: childPairs.map(\.node),
                    lastModified: completed.metadata.lastModified,
                    fileIdentity: completed.metadata.fileIdentity,
                    linkCount: completed.metadata.linkCount,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable,
                    childrenAreSorted: true
                )
                resolvedNodeByKey[key] = assembled
                if !childPairs.isEmpty {
                    sortedChildReferencesByKey[key] = childPairs.map(\.reference)
                }

                callbacks.directoryFinalized()
            } else if let onlyChild = completed.node {
                // Leaf node or inaccessible directory: use the child directly.
                resolvedNodeByKey[key] = onlyChild
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try callbacks.cancellationCheck()
                callbacks.progress(Double(finalizedItems) / Double(finalizationTotal))
            }
        }
        ScanTiming.record("scan.assemble.aggregate", (ContinuousClock.now - aggregateStart) - sortDuration)
        ScanTiming.record("scan.assemble.sort", sortDuration)

        guard resolvedNodeByKey[0] != nil else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }

        // Lay the assembled tree out as contiguous preorder arrays — the
        // scan keys stay Int end to end; the only string-keyed work left is
        // one id → index insert per node.
        let flattenStart = ContinuousClock.now
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        let estimatedNodeCount = resolvedNodeByKey.count + directLeafCount
        var indexByID = NodeIDIndex(minimumCapacity: estimatedNodeCount)
        nodes.reserveCapacity(estimatedNodeCount)
        parentIndices.reserveCapacity(estimatedNodeCount)
        var aggregateStats = AggregateStatsAccumulator()
        var buildStack: [(reference: AssemblyChildReference, parent: Int32)] = [(.keyed(0), -1)]
        while let (reference, parent) = buildStack.popLast() {
            if nodes.count.isMultiple(of: 1_024) {
                try callbacks.cancellationCheck()
            }
            let record: FileNodeRecord
            let childReferences: [AssemblyChildReference]
            switch reference {
            case .keyed(let key):
                guard let keyedRecord = resolvedNodeByKey[key] else { continue }
                record = keyedRecord
                childReferences = sortedChildReferencesByKey[key] ?? []
            case .direct(let directRecord):
                record = directRecord
                childReferences = []
            }
            let index = Int32(nodes.count)
            if let existing = indexByID.updateValue(index, forKey: record.id) {
                // Should be impossible (phase 1 dedupes by path); drop the
                // duplicate subtree and keep the first occurrence.
                indexByID[record.id] = existing
                callbacks.warning(ScanWarningFactory.makeDuplicateNodeWarning(for: record.url))
                continue
            }
            nodes.append(record)
            parentIndices.append(parent)
            aggregateStats.include(record, hasChildren: !childReferences.isEmpty)
            for childReference in childReferences.reversed() {
                buildStack.append((childReference, index))
            }
        }
        let (childStarts, initialChildSlots) = TreeStorage.childLayout(parentIndices: parentIndices)
        var childSlots = initialChildSlots
        ScanTiming.record("scan.assemble.flatten", ContinuousClock.now - flattenStart)

        let dedupStart = ContinuousClock.now
        HardLinkDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            indexByID: indexByID,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
        try CloneDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            indexByID: indexByID,
            cancellationCheck: callbacks.cancellationCheck
        )
        ScanTiming.record("scan.assemble.dedup", ContinuousClock.now - dedupStart)
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize",
            url: targetURL,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )
        #endif

        guard let rootNode = nodes.first else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }

        let indexStart = ContinuousClock.now
        let nodeHashes = NodeIDIndex.parallelHashes(of: nodes)
        ScanTiming.record("scan.assemble.index", ContinuousClock.now - indexStart)

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: indexByID,
                nodeHashes: nodeHashes
            ),
            rootID: rootNode.id,
            aggregateStats: aggregateStats.makeStats(root: rootNode)
        )
    }
}
