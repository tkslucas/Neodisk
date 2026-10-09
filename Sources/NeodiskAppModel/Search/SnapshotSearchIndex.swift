//
//  SnapshotSearchIndex.swift
//  Neodisk
//
//  The shared search infrastructure behind the outline's entire-scan search
//  and the kind drill-in list: one FileSearchEntry index built per displayed
//  snapshot (lazily, off the main actor; dropped when the snapshot changes)
//  and one debounce helper serving both search fields.
//

import Dispatch
import Foundation
import NeodiskKit

/// Every node of a displayed snapshot in searchable form, classified for
/// both kind display modes and sorted by allocated size descending — the
/// statistics file lists' browse order comes straight from a filter over
/// it, and their name filters preserve that order (see
/// FuzzyMatcher.matchesInEntryOrder).
package struct SnapshotSearchIndex: Sendable {
    package let snapshotID: UUID
    /// The tree root, which the outline search excludes from results.
    package let rootID: String
    package let entries: [FileSearchEntry]

    package static func build(store: FileTreeStore, snapshotID: UUID) -> SnapshotSearchIndex {
        let nodes = store.allNodes
        let nodeCount = nodes.count

        // Classifying millions of names is the slow part: do it in parallel
        // chunks, each with its own kind-ID codes, then merge the codes into
        // one table.
        struct Chunk {
            var codes: [(category: UInt32, type: UInt32, countable: Bool)] = []
            var kindIDs: [String] = []
            var lowercasedOverrides: [Int32: String] = [:]
        }
        let chunkCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16, nodeCount / 50_000))
        let chunkSize = (nodeCount + chunkCount - 1) / max(chunkCount, 1)
        var chunks = [Chunk](repeating: Chunk(), count: chunkCount)
        chunks.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let chunksOut = buffer
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                var chunk = Chunk()
                var codeByKindID: [String: UInt32] = [:]
                func code(_ kindID: String) -> UInt32 {
                    if let code = codeByKindID[kindID] { return code }
                    let code = UInt32(chunk.kindIDs.count)
                    chunk.kindIDs.append(kindID)
                    codeByKindID[kindID] = code
                    return code
                }
                let range = min(chunkIndex * chunkSize, nodeCount)..<min((chunkIndex + 1) * chunkSize, nodeCount)
                chunk.codes.reserveCapacity(range.count)
                for i in range {
                    if i & 4095 == 0, Task.isCancelled { break }
                    let node = nodes[i]
                    chunk.codes.append((
                        code(FileKindClassifier.kindID(for: node, mode: .categories)),
                        code(FileKindClassifier.kindID(for: node, mode: .types)),
                        FileKindClassifier.isKindCountable(node, in: store)
                    ))
                    if !SearchEntryTable.asciiFoldingLowercases(node.name) {
                        chunk.lowercasedOverrides[Int32(i)] = node.name.lowercased()
                    }
                }
                chunksOut[chunkIndex] = chunk
            }
        }

        var kindIDs: [String] = []
        var codeByKindID: [String: UInt32] = [:]
        var lowercasedOverrides: [Int32: String] = [:]
        let remaps = chunks.map { chunk in
            lowercasedOverrides.merge(chunk.lowercasedOverrides) { first, _ in first }
            return chunk.kindIDs.map { kindID in
                if let code = codeByKindID[kindID] { return code }
                let code = UInt32(kindIDs.count)
                kindIDs.append(kindID)
                codeByKindID[kindID] = code
                return code
            }
        }
        let table = SearchEntryTable(nodes: nodes, kindIDs: kindIDs, lowercasedOverrides: lowercasedOverrides)

        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(nodeCount)
        for (chunkIndex, chunk) in chunks.enumerated() {
            let remap = remaps[chunkIndex]
            let base = chunkIndex * chunkSize
            for (offset, codes) in chunk.codes.enumerated() {
                let index = base + offset
                entries.append(FileSearchEntry(
                    table: table,
                    nodeIndex: Int32(index),
                    categoryCode: remap[Int(codes.category)],
                    typeCode: remap[Int(codes.type)],
                    isKindCountable: codes.countable,
                    allocatedSize: nodes[index].allocatedSize
                ))
            }
        }
        entries.sort { $0.allocatedSize > $1.allocatedSize }
        return SnapshotSearchIndex(snapshotID: snapshotID, rootID: store.rootID, entries: entries)
    }
}

@MainActor
package final class SearchIndexService {
    private var buildTask: Task<SnapshotSearchIndex, Never>?
    private var builtSnapshotID: UUID?

    package init() {}

    /// The displayed tree changed: the cached index holds dead node IDs.
    package func invalidate() {
        buildTask?.cancel()
        buildTask = nil
        builtSnapshotID = nil
    }

    package func index(for snapshot: ScanSnapshot) async -> SnapshotSearchIndex {
        if builtSnapshotID == snapshot.id, let buildTask {
            return await buildTask.value
        }
        invalidate()
        let store = snapshot.treeStore
        let snapshotID = snapshot.id
        builtSnapshotID = snapshotID
        let task = Task.detached(priority: .userInitiated) {
            SnapshotSearchIndex.build(store: store, snapshotID: snapshotID)
        }
        buildTask = task
        return await task.value
    }
}

/// Shared debounce for the search fields: scheduling cancels the previous
/// operation — including any post-debounce work still in flight, which
/// observes the cancellation through `Task.isCancelled` — and runs the new
/// one after the interval.
@MainActor
package final class SearchDebouncer {
    package static let interval: Duration = .milliseconds(180)

    private var task: Task<Void, Never>?

    package init() {}

    package func schedule(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task {
            guard (try? await Task.sleep(for: Self.interval)) != nil else { return }
            await operation()
        }
    }

    package func cancel() {
        task?.cancel()
        task = nil
    }
}
