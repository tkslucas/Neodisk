import Foundation

/// Phase 2 of a scan: turns phase-1 state into the `FileTreeStore`. Side effects go back through
/// `Callbacks`, only ever invoked on the scan task, never from a parallel section.
nonisolated enum ScanTreeAssembler {
    typealias CompletedDirScan = ScanEngine.CompletedDirScan
    typealias AssemblyChildReference = ScanTraversal.AssemblyChildReference
    typealias AggregateStatsAccumulator = ScanTraversal.AggregateStatsAccumulator

    /// Called only on the scan task, in order, so they may touch scan-confined state. Defaults are no-ops for
    /// tests.
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

    /// `leafIndex == -1` is a keyed child. A POD pair of `Int32`s so child ordering sorts 8-byte elements
    /// instead of the ~330-byte record tuples the legacy path moved.
    struct ChildRef {
        var key: Int32
        var leafIndex: Int32
    }

    /// Byte-identical to `legacyAssemble`, which it forwards to on a duplicate id (dedups and warns).
    /// Phase-1 state is never mutated here, so that fallback starts clean.
    static func assemble(
        completedByKey: [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64],
        targetURL: URL,
        diagnostics: ScanDiagnosticsContext?,
        clonePrivateSizeProvider: @escaping CloneDeduplicator.PrivateSizeProvider = CloneDeduplicator.systemPrivateSize,
        callbacks: Callbacks
    ) throws -> FileTreeStore {
        guard nextKey > 0 else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif

        // Step 1: children have higher keys than their parent, so one reverse pass resolves totals bottom-up.
        // Replicates FileNodeRecord.directory's field choices exactly.
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
                if let totals = completed.directLeafTotals {
                    // Summed by the directory worker over the same records.
                    a = totals.allocatedSize
                    l = totals.logicalSize
                    c = totals.cloudOnlyLogicalSize
                    files = totals.descendantFileCount
                    accessible = accessible && totals.isAccessible
                } else {
                    for leaf in completed.directLeafNodes {
                        a = a.addingClamped(leaf.allocatedSize)
                        l = l.addingClamped(leaf.logicalSize)
                        c = c.addingClamped(leaf.cloudOnlyLogicalSize)
                        files += leaf.isDirectory
                            ? leaf.descendantFileCount
                            : (leaf.isSymbolicLink || leaf.isSynthetic ? 0 : 1)
                        accessible = accessible && leaf.isAccessible
                    }
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
                sortName[key] = completed.name
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
        // Bands weighted by measured cost on a clone-heavy home dir: clone dedup gets half so the bar doesn't
        // freeze.
        callbacks.progress(0.1)

        // Step 2: same input order, comparator and sort as legacy, so ties keep its permutation. Sequential:
        // parallel sorts measured slower (the name tie-break contends on ICU locks and retains).
        let sortStart = ContinuousClock.now
        var childRefsByKey = [[ChildRef]](repeating: [], count: nextKey)
        for key in 0..<nextKey where isTraversableDir[key] {
            if key.isMultiple(of: 1_024) {
                try callbacks.cancellationCheck()
            }
            guard let completed = completedByKey[key] else { continue }
            let directLeaves = completed.directLeafNodes
            func precedes(_ lhs: ChildRef, _ rhs: ChildRef) -> Bool {
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
                    return DisplayNameOrder.precedes(lhsName, rhsName)
                }
                return lhsAllocated > rhsAllocated
            }
            // Files arrive presorted, so only subfolders are sorted and binary-searched in after tying files:
            // the stable sort's result without slow name compares between files.
            guard completed.directLeafNodesAreSorted else {
                var refs: [ChildRef] = []
                refs.reserveCapacity(directLeaves.count + childrenKeysByKey[key].count)
                for leafIndex in 0..<directLeaves.count {
                    refs.append(ChildRef(key: Int32(key), leafIndex: Int32(leafIndex)))
                }
                for childKey in childrenKeysByKey[key] where resolved[childKey] {
                    refs.append(ChildRef(key: Int32(childKey), leafIndex: -1))
                }
                refs.sort(by: precedes)
                childRefsByKey[key] = refs
                continue
            }
            #if DEBUG
            for index in directLeaves.indices.dropFirst() {
                assert(!precedes(
                    ChildRef(key: Int32(key), leafIndex: Int32(index)),
                    ChildRef(key: Int32(key), leafIndex: Int32(index - 1))
                ), "direct leaves of \(completed.url.path) arrived unsorted")
            }
            #endif
            var folderRefs: [ChildRef] = []
            for childKey in childrenKeysByKey[key] where resolved[childKey] {
                folderRefs.append(ChildRef(key: Int32(childKey), leafIndex: -1))
            }
            let folderSortSince = ScanProfile.now()
            #if canImport(Darwin)
            if folderRefs.count > 1 {
                // Names bridged once each, not on every tie comparison.
                let keyed = folderRefs.map { ref in
                    (ref: ref, size: allocated[Int(ref.key)], name: sortName[Int(ref.key)] as NSString)
                }
                folderRefs = keyed.sorted { lhs, rhs in
                    lhs.size == rhs.size
                        ? DisplayNameOrder.precedes(lhs.name, rhs.name)
                        : lhs.size > rhs.size
                }.map(\.ref)
            }
            #else
            folderRefs.sort(by: precedes)
            #endif
            ScanProfile.end(.assemblyFolderSort, since: folderSortSince, count: folderRefs.count)
            var refs: [ChildRef] = []
            refs.reserveCapacity(directLeaves.count + folderRefs.count)
            var nextLeaf = 0
            for folder in folderRefs {
                var low = nextLeaf
                var high = directLeaves.count
                while low < high {
                    let middle = (low + high) / 2
                    if precedes(folder, ChildRef(key: Int32(key), leafIndex: Int32(middle))) {
                        high = middle
                    } else {
                        low = middle + 1
                    }
                }
                for leafIndex in nextLeaf..<low {
                    refs.append(ChildRef(key: Int32(key), leafIndex: Int32(leafIndex)))
                }
                refs.append(folder)
                nextLeaf = low
            }
            for leafIndex in nextLeaf..<directLeaves.count {
                refs.append(ChildRef(key: Int32(key), leafIndex: Int32(leafIndex)))
            }
            childRefsByKey[key] = refs
        }
        ScanTiming.record("scan.assemble.sort", ContinuousClock.now - sortStart)
        callbacks.progress(0.35)

        // Step 3: single-pass preorder flatten; each node is materialized exactly once.
        let flattenStart = ContinuousClock.now
        let estimatedNodeCount = resolvedCount + directLeafTotal
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        nodes.reserveCapacity(estimatedNodeCount)
        parentIndices.reserveCapacity(estimatedNodeCount)
        var aggregateStats = AggregateStatsAccumulator()
        let progressStride = max(estimatedNodeCount / 20, 1)
        // Files are emitted from the folder's list fetched once per visit: reading `completedByKey[key]!`
        // per file copied the folder's whole scan record each time.
        enum FlattenStep {
            case keyed(key: Int32, parent: Int32)
            case resume(key: Int32, index: Int32, nextRef: Int)
        }
        func emit(_ record: FileNodeRecord, parent: Int32, hasChildren: Bool) throws -> Int32 {
            if nodes.count.isMultiple(of: 1_024) {
                try callbacks.cancellationCheck()
                if nodes.count.isMultiple(of: progressStride) {
                    let fraction = 0.35 + 0.1 * Double(nodes.count) / Double(max(estimatedNodeCount, 1))
                    callbacks.progress(min(fraction, 0.45))
                }
            }
            let index = Int32(nodes.count)
            nodes.append(record)
            parentIndices.append(parent)
            aggregateStats.include(record, hasChildren: hasChildren)
            return index
        }
        var stack: [FlattenStep] = [.keyed(key: 0, parent: -1)]
        while let step = stack.popLast() {
            switch step {
            case .keyed(let keyValue, let parent):
                let key = Int(keyValue)
                let completed = completedByKey[key]!
                if isTraversableDir[key] {
                    let refs = childRefsByKey[key]
                    let index = try emit(FileNodeRecord(
                        id: completed.path,
                        path: completed.path,
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
                    ), parent: parent, hasChildren: !refs.isEmpty)
                    if !refs.isEmpty {
                        stack.append(.resume(key: keyValue, index: index, nextRef: 0))
                    }
                } else {
                    _ = try emit(completed.node!, parent: parent, hasChildren: false)
                }
            case .resume(let keyValue, let index, let nextRef):
                let key = Int(keyValue)
                let refs = childRefsByKey[key]
                let leaves = completedByKey[key]!.directLeafNodes
                var position = nextRef
                while position < refs.count {
                    let ref = refs[position]
                    position += 1
                    if ref.leafIndex >= 0 {
                        _ = try emit(leaves[Int(ref.leafIndex)], parent: index, hasChildren: false)
                    } else {
                        if position < refs.count {
                            stack.append(.resume(key: keyValue, index: index, nextRef: position))
                        }
                        stack.append(.keyed(key: ref.key, parent: index))
                        break
                    }
                }
            }
        }
        let (childStarts, initialChildSlots) = TreeStorage.childLayout(parentIndices: parentIndices)
        var childSlots = initialChildSlots
        ScanTiming.record("scan.assemble.flatten", ContinuousClock.now - flattenStart)

        // Step 4: parallel id index (detects duplicates, which hand off to legacy), then shared-block dedup.
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
                clonePrivateSizeProvider: clonePrivateSizeProvider,
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
            privateSizeProvider: clonePrivateSizeProvider,
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

    private struct FlattenEntry {
        var key: Int32
        var leafIndex: Int32
        var parent: Int32
    }

    /// The pre-rework assembly, kept verbatim as the fast path's correctness oracle and duplicate-id fallback.
    /// Consumes `completedByKey` so the large leaf batches free as the reverse pass drops each key.
    static func legacyAssemble(
        completedByKey: consuming [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64],
        targetURL: URL,
        diagnostics: ScanDiagnosticsContext?,
        clonePrivateSizeProvider: @escaping CloneDeduplicator.PrivateSizeProvider = CloneDeduplicator.systemPrivateSize,
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
                    isAccessible: completed.metadata.isReadable
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

        // Scan keys stay Int end to end; the only string-keyed work left is one id insert per node.
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
            if indexByID.insertIfAbsent(index, forKey: record.id) != nil {
                // Should be impossible (phase 1 dedupes by path); drop the
                // duplicate subtree and keep the first occurrence.
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
            privateSizeProvider: clonePrivateSizeProvider,
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
