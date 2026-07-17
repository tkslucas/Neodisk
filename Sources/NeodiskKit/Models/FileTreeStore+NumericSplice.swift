//
//  FileTreeStore+NumericSplice.swift
//  Neodisk
//
//  The numeric fast path behind `replacingSubtrees` and `applyingRootRelist`:
//  splices replacement subtrees, inserts new ones, removes gone ones, and
//  refreshes the root's own record directly at the contiguous-array level,
//  instead of round-tripping the whole store through dictionary topology. The
//  dictionary path costs O(baseline) in string hashing and record dictionaries
//  (~6.5s of a ~9.4s splice on a 1.6M-node home dir) for any change size; this
//  path's per-node work is plain Int32/array copies, with the only string-keyed
//  pass the parallel id-index rebuild.
//
//  Every edit — replace, insert, remove, root-record refresh — is applied in a
//  single copy pass followed by one ancestor rebuild and one shared-size
//  rebalance, so a root relist that adds a folder while replacing a deep
//  subtree never pays two O(baseline) rebalances.
//
//  `legacyReplacingSubtrees` / `legacyApplyingRootRelist` (the dictionary paths)
//  stay as the correctness oracles and as the fallback for stores this path
//  declines (non-contiguous subtree layout, duplicate ids) — see
//  `FileTreeStoreSpliceEquivalenceTests`.
//

import Foundation

extension FileTreeStore {
    /// Three-way outcome so the dispatcher can distinguish "target invalid"
    /// (public contract: return nil) from "this store's layout defeats the
    /// numeric path" (fall back to the dictionary oracle).
    enum NumericSpliceOutcome {
        case spliced(FileTreeStore)
        case invalidTarget
        case unsupported
    }

    /// One new subtree to graft under an existing, surviving parent.
    struct SubtreeInsertion {
        var parentID: String
        var store: FileTreeStore
    }

    /// One substituted or removed baseline subtree resolved against the arrays:
    /// the preorder range it occupies and, for a replacement, the store taking
    /// its place (`nil` for a removal, which contributes zero new nodes).
    private struct ResolvedTarget {
        var rangeStart: Int32
        var rangeCount: Int32
        /// Index into the caller's `replacements` array, or -1 for a removal.
        var replacementIndex: Int
        var oldParentIndex: Int32
    }

    /// Numeric replace-only splice, preserved as the hot-path entry point and
    /// the surface the randomized equivalence suite exercises directly.
    nonisolated func numericReplacingSubtrees(
        _ replacements: [(id: String, store: FileTreeStore)],
        spliceProgress: (Double) -> Void = { _ in },
        cancellationCheck: () throws -> Void
    ) throws -> NumericSpliceOutcome {
        try numericApplyEdits(
            replacements: replacements,
            removingSubtreeIDs: [],
            insertions: [],
            rootRecordOverride: nil,
            spliceProgress: spliceProgress,
            cancellationCheck: cancellationCheck
        )
    }

    /// The unified numeric edit pass. `replacements` substitute existing
    /// subtrees, `removingSubtreeIDs` delete them, `insertions` graft new ones
    /// under a surviving parent, and `rootRecordOverride` refreshes the root's
    /// own record fields (its totals are re-derived by the rebuild). All edits
    /// are validated up front, then applied in one copy + rebuild + rebalance.
    nonisolated func numericApplyEdits(
        replacements: [(id: String, store: FileTreeStore)],
        removingSubtreeIDs: [String],
        insertions: [SubtreeInsertion],
        rootRecordOverride: FileNodeRecord?,
        spliceProgress: (Double) -> Void = { _ in },
        cancellationCheck: () throws -> Void
    ) throws -> NumericSpliceOutcome {
        try cancellationCheck()
        if replacements.isEmpty, removingSubtreeIDs.isEmpty, insertions.isEmpty,
           rootRecordOverride == nil {
            return .spliced(self)
        }
        let storage = storage
        let oldCount = storage.count

        if let rootRecordOverride, rootRecordOverride.id != rootID {
            return .unsupported
        }

        // Validate replacement targets first (existence, non-root, well-formed
        // single-root store) so the outcome precedence matches the replace-only
        // legacy path: a missing or root target is `invalidTarget` (public nil)
        // before any structural surprise becomes `unsupported`, and both come
        // before an overlap throw.
        var resolved: [ResolvedTarget] = []
        resolved.reserveCapacity(replacements.count + removingSubtreeIDs.count)

        for (slot, replacement) in replacements.enumerated() {
            guard let targetIndex = storage.index(of: replacement.id) else { return .invalidTarget }
            if replacement.id == rootID { return .invalidTarget }
            guard let parentIndex = storage.parentIndex(of: targetIndex) else { return .invalidTarget }
            let store = replacement.store
            guard store.storage.index(of: store.rootID) == 0 else { return .unsupported }
            for (local, parent) in store.storage.parentIndices.enumerated()
            where parent < 0 && local != 0 {
                return .unsupported
            }
            resolved.append(ResolvedTarget(
                rangeStart: targetIndex,
                rangeCount: 0,
                replacementIndex: slot,
                oldParentIndex: parentIndex
            ))
        }

        for removalID in removingSubtreeIDs {
            guard let targetIndex = storage.index(of: removalID) else { return .unsupported }
            if removalID == rootID { return .unsupported }
            guard let parentIndex = storage.parentIndex(of: targetIndex) else { return .unsupported }
            resolved.append(ResolvedTarget(
                rangeStart: targetIndex,
                rangeCount: 0,
                replacementIndex: -1,
                oldParentIndex: parentIndex
            ))
        }

        // Targets must be pairwise disjoint: no duplicates, and none an
        // ancestor of another. An exact duplicate is a degenerate overlap.
        var targetIndexSet = Set<Int32>()
        for target in resolved where !targetIndexSet.insert(target.rangeStart).inserted {
            let id = storage.nodes[Int(target.rangeStart)].id
            throw StoreError.overlappingReplacementTargets(id, id)
        }
        for target in resolved {
            try cancellationCheck()
            var cursor = storage.parentIndices[Int(target.rangeStart)]
            while cursor >= 0 {
                if targetIndexSet.contains(cursor) {
                    throw StoreError.overlappingReplacementTargets(
                        storage.nodes[Int(cursor)].id,
                        storage.nodes[Int(target.rangeStart)].id
                    )
                }
                cursor = storage.parentIndices[Int(cursor)]
            }
        }

        // Insertion parents must exist and survive (not lie inside a removed or
        // replaced range); each insertion store must be a well-formed
        // single-root tree whose root id is new to the baseline.
        var insertionParentIndices: [Int32] = []
        insertionParentIndices.reserveCapacity(insertions.count)
        for insertion in insertions {
            guard let parentIndex = storage.index(of: insertion.parentID) else { return .unsupported }
            let store = insertion.store
            guard store.storage.index(of: store.rootID) == 0 else { return .unsupported }
            for (local, parent) in store.storage.parentIndices.enumerated()
            where parent < 0 && local != 0 {
                return .unsupported
            }
            insertionParentIndices.append(parentIndex)
        }

        // Resolve each substitution/removal target's preorder range. Preorder
        // makes every subtree a contiguous run starting at its root; verify
        // rather than assume, and hand any surprise to the dictionary path.
        for i in resolved.indices {
            try cancellationCheck()
            let targetIndex = resolved[i].rangeStart
            var count = 0
            var maxIndex = targetIndex
            var stack = [targetIndex]
            while let current = stack.popLast() {
                count += 1
                if current > maxIndex { maxIndex = current }
                stack.append(contentsOf: storage.childIndices(of: current))
            }
            guard Int(maxIndex - targetIndex) + 1 == count else { return .unsupported }
            resolved[i].rangeCount = Int32(count)
        }
        resolved.sort { $0.rangeStart < $1.rangeStart }

        // An insertion parent must survive: reject if it falls inside any
        // removed or replaced range.
        let sortedRangeStarts = resolved.map(\.rangeStart)
        func isInsideRange(_ index: Int32) -> Bool {
            var low = 0
            var high = sortedRangeStarts.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if sortedRangeStarts[mid] > index {
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
            guard high >= 0 else { return false }
            return index < resolved[high].rangeStart + resolved[high].rangeCount
        }
        for parentIndex in insertionParentIndices where isInsideRange(parentIndex) {
            return .unsupported
        }

        // Collision preflight: a replacement/insertion id may only reuse a
        // baseline id that lies inside one of the removed/replaced ranges, and
        // no two grafted stores may introduce the same id.
        var seenGraftIDs = Set<String>()
        func preflight(_ store: FileTreeStore) throws {
            for (offset, node) in store.storage.nodes.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                if let existing = storage.index(of: node.id), !isInsideRange(existing) {
                    throw StoreError.replacementIDCollision(node.id)
                }
                if !seenGraftIDs.insert(node.id).inserted {
                    throw StoreError.replacementIDCollision(node.id)
                }
            }
        }
        for replacement in replacements { try preflight(replacement.store) }
        for insertion in insertions { try preflight(insertion.store) }

        // Placement pass: where every kept segment, replacement, and appended
        // insertion lands in the new arrays, plus the old→new map for kept
        // nodes.
        let copyStart = ContinuousClock.now
        let removedTotal = resolved.reduce(0) { $0 + Int($1.rangeCount) }
        let replacementTotal = replacements.reduce(0) { $0 + $1.store.storage.count }
        let insertionTotal = insertions.reduce(0) { $0 + $1.store.storage.count }
        let newCount = oldCount - removedTotal + replacementTotal + insertionTotal

        var oldToNew = [Int32](repeating: -1, count: oldCount)
        var replacementBase = [Int32](repeating: -1, count: replacements.count)
        var insertionBase = [Int32](repeating: -1, count: insertions.count)
        var newNodes: [FileNodeRecord] = []
        newNodes.reserveCapacity(newCount)
        var newParents = [Int32](repeating: -1, count: newCount)

        var writeIndex: Int32 = 0
        var readCursor: Int32 = 0
        var keptSegments: [(oldStart: Int32, oldEnd: Int32)] = []
        for target in resolved {
            if readCursor < target.rangeStart {
                keptSegments.append((readCursor, target.rangeStart))
                for oldIndex in readCursor..<target.rangeStart {
                    oldToNew[Int(oldIndex)] = writeIndex + (oldIndex - readCursor)
                }
                writeIndex += target.rangeStart - readCursor
            }
            if target.replacementIndex >= 0 {
                replacementBase[target.replacementIndex] = writeIndex
                writeIndex += Int32(replacements[target.replacementIndex].store.storage.count)
            }
            // A removal contributes no nodes; just skip its old range.
            readCursor = target.rangeStart + target.rangeCount
        }
        if readCursor < Int32(oldCount) {
            keptSegments.append((readCursor, Int32(oldCount)))
            for oldIndex in readCursor..<Int32(oldCount) {
                oldToNew[Int(oldIndex)] = writeIndex + (oldIndex - readCursor)
            }
            writeIndex += Int32(oldCount) - readCursor
        }
        // Insertions land after every kept/replaced node.
        for (slot, insertion) in insertions.enumerated() {
            insertionBase[slot] = writeIndex
            writeIndex += Int32(insertion.store.storage.count)
        }

        // Copy pass. A kept node's parent is always kept (a removed parent
        // would put the node inside a removed/replaced range), so the map
        // lookup never misses; a grafted store's internal parents shift by its
        // base and its root re-parents onto the mapped old parent.
        var segmentCursor = 0
        var substitutionCursor = 0
        var emitted: Int32 = 0
        let keptAndReplacedCount = Int32(oldCount) - Int32(removedTotal) + Int32(replacementTotal)
        while emitted < keptAndReplacedCount {
            try cancellationCheck()
            // Removals emit nothing; step over them so the merge interleaves
            // only kept segments and replacement blocks, by new index.
            while substitutionCursor < resolved.count,
                  resolved[substitutionCursor].replacementIndex < 0 {
                substitutionCursor += 1
            }
            let nextKept = segmentCursor < keptSegments.count
                ? oldToNew[Int(keptSegments[segmentCursor].oldStart)] : Int32.max
            let nextReplacement = substitutionCursor < resolved.count
                ? replacementBase[resolved[substitutionCursor].replacementIndex] : Int32.max
            if nextKept <= nextReplacement {
                let segment = keptSegments[segmentCursor]
                newNodes.append(contentsOf: storage.nodes[Int(segment.oldStart)..<Int(segment.oldEnd)])
                for oldIndex in segment.oldStart..<segment.oldEnd {
                    let parent = storage.parentIndices[Int(oldIndex)]
                    newParents[Int(oldToNew[Int(oldIndex)])] = parent < 0 ? -1 : oldToNew[Int(parent)]
                }
                emitted += segment.oldEnd - segment.oldStart
                segmentCursor += 1
            } else {
                let target = resolved[substitutionCursor]
                substitutionCursor += 1
                let replacement = replacements[target.replacementIndex].store
                let base = replacementBase[target.replacementIndex]
                let replacementStorage = replacement.storage
                let mappedParent = oldToNew[Int(target.oldParentIndex)]
                newNodes.append(contentsOf: replacementStorage.nodes)
                newParents[Int(base)] = mappedParent
                for local in 1..<max(replacementStorage.count, 1) {
                    newParents[Int(base) + local] = base + replacementStorage.parentIndices[local]
                }
                emitted += Int32(replacementStorage.count)
            }
        }
        for (slot, insertion) in insertions.enumerated() {
            try cancellationCheck()
            let base = insertionBase[slot]
            let insertionStorage = insertion.store.storage
            let mappedParent = oldToNew[Int(insertionParentIndices[slot])]
            newNodes.append(contentsOf: insertionStorage.nodes)
            newParents[Int(base)] = mappedParent
            for local in 1..<max(insertionStorage.count, 1) {
                newParents[Int(base) + local] = base + insertionStorage.parentIndices[local]
            }
        }

        // The root is always the first kept node, so its refreshed record lands
        // at index 0. Its totals are re-derived by the rebuild below when
        // membership moved, and preserved as-is otherwise.
        if let rootRecordOverride {
            newNodes[0] = rootRecordOverride
        }

        // Child layout: counts + prefix sums, then per-parent slot fills that
        // preserve each parent's existing display order — kept parents keep
        // their old slot order with each replaced child substituted in place
        // and removed children dropped; grafted parents keep their store's
        // internal order; inserted roots append to their parent. Affected
        // parents are re-sorted by the rebuild, so append order is cosmetic.
        var newChildStarts = [Int32](repeating: 0, count: newCount + 1)
        for parent in newParents where parent >= 0 {
            newChildStarts[Int(parent) + 1] += 1
        }
        for i in 1...newCount {
            newChildStarts[i] += newChildStarts[i - 1]
        }
        var slotCursors = newChildStarts
        var newChildSlots = [Int32](repeating: 0, count: Int(newChildStarts[newCount]))

        var replacementRootNewIndexByOldTarget: [Int32: Int32] = [:]
        var removedTargetOldIndices = Set<Int32>()
        replacementRootNewIndexByOldTarget.reserveCapacity(replacements.count)
        for target in resolved {
            if target.replacementIndex >= 0 {
                replacementRootNewIndexByOldTarget[target.rangeStart] =
                    replacementBase[target.replacementIndex]
            } else {
                removedTargetOldIndices.insert(target.rangeStart)
            }
        }
        for segment in keptSegments {
            try cancellationCheck()
            for oldIndex in segment.oldStart..<segment.oldEnd {
                let newParent = Int(oldToNew[Int(oldIndex)])
                for oldChild in storage.childIndices(of: oldIndex) {
                    if removedTargetOldIndices.contains(oldChild) { continue }
                    let mapped = oldToNew[Int(oldChild)] >= 0
                        ? oldToNew[Int(oldChild)]
                        : replacementRootNewIndexByOldTarget[oldChild]!
                    newChildSlots[Int(slotCursors[newParent])] = mapped
                    slotCursors[newParent] += 1
                }
            }
        }
        for target in resolved where target.replacementIndex >= 0 {
            try cancellationCheck()
            let replacement = replacements[target.replacementIndex].store
            let base = replacementBase[target.replacementIndex]
            let replacementStorage = replacement.storage
            for local in 0..<replacementStorage.count {
                let newParent = Int(base) + local
                for localChild in replacementStorage.childIndices(of: Int32(local)) {
                    newChildSlots[Int(slotCursors[newParent])] = base + localChild
                    slotCursors[newParent] += 1
                }
            }
        }
        for (slot, insertion) in insertions.enumerated() {
            try cancellationCheck()
            let base = insertionBase[slot]
            let insertionStorage = insertion.store.storage
            let mappedParent = Int(oldToNew[Int(insertionParentIndices[slot])])
            newChildSlots[Int(slotCursors[mappedParent])] = base
            slotCursors[mappedParent] += 1
            for local in 0..<insertionStorage.count {
                let newParent = Int(base) + local
                for localChild in insertionStorage.childIndices(of: Int32(local)) {
                    newChildSlots[Int(slotCursors[newParent])] = base + localChild
                    slotCursors[newParent] += 1
                }
            }
        }
        ScanTiming.record("rescan.splice.copy", ContinuousClock.now - copyStart)
        // Four coarse boundaries feed the strip's "Applying changes…" band so a
        // multi-second merge on a huge baseline shows honest forward motion
        // rather than a static hold. Stride-free (one call per phase), so it
        // adds no measurable cost. Rebalance dominates on real trees, so it
        // owns the largest slice.
        spliceProgress(0.25)

        // Parallel id-index rebuild — the one unavoidable full string pass.
        // A duplicate id here means the collision preflight's assumptions
        // were violated; the legacy path knows how to dedup-and-warn.
        let indexStart = ContinuousClock.now
        guard let built = NodeIDIndex.building(from: newNodes) else { return .unsupported }
        ScanTiming.record("rescan.splice.index", ContinuousClock.now - indexStart)
        spliceProgress(0.4)

        // Ancestor re-aggregation (totals + display re-sort) over every parent
        // whose membership moved and its own ancestors, then the scan-wide
        // shared-size rebalance the legacy path also finishes with. Removals
        // leave no node to seed an ancestor walk from, so the affected parents
        // are gathered directly rather than as the ancestor closure of new
        // nodes.
        let rebuildStart = ContinuousClock.now
        var nodes = newNodes
        var childSlots = newChildSlots
        var affectedDirectories = Set<Int32>()
        func addSelfAndAncestors(_ newIndex: Int32) {
            var cursor = newIndex
            while cursor >= 0, affectedDirectories.insert(cursor).inserted {
                cursor = newParents[Int(cursor)]
            }
        }
        for target in resolved {
            addSelfAndAncestors(oldToNew[Int(target.oldParentIndex)])
        }
        for parentIndex in insertionParentIndices {
            addSelfAndAncestors(oldToNew[Int(parentIndex)])
        }
        try HardLinkDeduplicator.rebuildDirectories(
            affectedDirectories,
            nodes: &nodes,
            parentIndices: newParents,
            childStarts: newChildStarts,
            childSlots: &childSlots,
            cancellationCheck: cancellationCheck
        )
        ScanTiming.record("rescan.splice.rebuild", ContinuousClock.now - rebuildStart)
        spliceProgress(0.55)

        let rebalanceStart = ContinuousClock.now
        let updatedStore = FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: newParents,
                childStarts: newChildStarts,
                childSlots: childSlots,
                indexByID: built.index,
                nodeHashes: built.hashes
            ),
            rootID: rootID
        )
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(
            updatedStore,
            cancellationCheck: cancellationCheck
        )
        ScanTiming.record("rescan.splice.rebalance", ContinuousClock.now - rebalanceStart)
        spliceProgress(1.0)
        return .spliced(rebalanced)
    }
}
