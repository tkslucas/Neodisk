// Numeric fast path for splices: array-level edits in one copy pass, one ancestor rebuild and one rebalance,
// instead of the dictionary path's O(baseline) string hashing. That path stays as the correctness oracle.

import Foundation

extension FileTreeStore {
    /// Separates "target invalid" (public nil) from "layout defeats the numeric path" (fall back to the oracle).
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

    /// A target's preorder range plus its replacement store (`nil` for a removal).
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
            recordOverrides: [:],
            spliceProgress: spliceProgress,
            cancellationCheck: cancellationCheck
        )
    }

    /// Replaces, removes, inserts and refreshes surviving directories' own records (totals are re-derived).
    /// Everything is validated up front, then applied in one copy, rebuild and rebalance.
    nonisolated func numericApplyEdits(
        replacements: [(id: String, store: FileTreeStore)],
        removingSubtreeIDs: [String],
        insertions: [SubtreeInsertion],
        recordOverrides: [String: FileNodeRecord],
        spliceProgress: (Double) -> Void = { _ in },
        cancellationCheck: () throws -> Void
    ) throws -> NumericSpliceOutcome {
        try cancellationCheck()
        if replacements.isEmpty, removingSubtreeIDs.isEmpty, insertions.isEmpty,
           recordOverrides.isEmpty {
            return .spliced(self)
        }
        let storage = storage
        let oldCount = storage.count

        // A mismatched override id is a caller bug, not a layout the dictionary path could rescue.
        for (id, record) in recordOverrides where record.id != id || storage.index(of: id) == nil {
            return .unsupported
        }

        // Replacement targets are validated first so outcome precedence matches the legacy path: `invalidTarget`
        // before `unsupported`, and both before an overlap throw.
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

        // Insertion parents must survive the edit, and each insertion root id must be new to the baseline.
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

        // Preorder should make each subtree contiguous; verify rather than assume, and hand surprises to the
        // dictionary path.
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

        // A grafted id may only reuse a baseline id inside a removed/replaced range, and never another graft's.
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

        // A kept node's parent is always kept, so the map lookup never misses; a grafted root re-parents onto
        // the mapped old parent.
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

        // An override inside a removed or replaced range has no surviving node (a caller bug), so hand the whole
        // edit to the dictionary path rather than write astray.
        for (id, record) in recordOverrides {
            let newIndex = oldToNew[Int(storage.index(of: id)!)]
            guard newIndex >= 0 else { return .unsupported }
            newNodes[Int(newIndex)] = record
        }

        // Each parent keeps its existing child order with replacements substituted in place; inserted roots
        // append, which is cosmetic because affected parents are re-sorted.
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
        // Coarse phase boundaries so a multi-second merge shows forward motion; rebalance dominates, so it owns
        // the largest slice.
        spliceProgress(0.25)

        // The one unavoidable full string pass. A duplicate here means the preflight was wrong; the legacy path
        // can dedup and warn.
        let indexStart = ContinuousClock.now
        guard let built = NodeIDIndex.building(from: newNodes) else { return .unsupported }
        ScanTiming.record("rescan.splice.index", ContinuousClock.now - indexStart)
        spliceProgress(0.4)

        // Removals leave no node to seed an ancestor walk from, so affected parents are gathered directly rather
        // than as the ancestor closure of new nodes.
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
        try AncestorRebuilder.rebuildDirectories(
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
        // Only families touched by the edit can change; a scan-wide rebalance cost ~0.3 s per home-folder rescan.
        var scope = SharedSizeDeduplication.Scope()
        for target in resolved {
            for index in Int(target.rangeStart)..<Int(target.rangeStart + target.rangeCount) {
                scope.include(storage.nodes[index])
            }
        }
        for replacement in replacements {
            for node in replacement.store.storage.nodes { scope.include(node) }
        }
        for insertion in insertions {
            for node in insertion.store.storage.nodes { scope.include(node) }
        }
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(
            updatedStore,
            scope: scope,
            cancellationCheck: cancellationCheck
        )
        ScanTiming.record("rescan.splice.rebalance", ContinuousClock.now - rebalanceStart)
        spliceProgress(1.0)
        return .spliced(rebalanced)
    }
}
