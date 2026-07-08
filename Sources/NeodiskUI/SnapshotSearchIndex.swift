//
//  SnapshotSearchIndex.swift
//  Neodisk
//
//  The shared search infrastructure behind the outline's entire-scan search
//  and the kind drill-in list: one FileSearchEntry index built per displayed
//  snapshot (lazily, off the main actor; dropped when the snapshot changes)
//  and one debounce helper serving both search fields.
//

import Foundation
import NeodiskKit

/// Every node of a displayed snapshot in searchable form, classified for
/// both kind display modes and sorted by allocated size descending — the
/// kind drill-in's browse order comes straight from a filter over it, and
/// fuzzy matching doesn't care about entry order.
struct SnapshotSearchIndex: Sendable {
    let snapshotID: UUID
    /// The tree root, which the outline search excludes from results.
    let rootID: String
    let entries: [FileSearchEntry]

    static func build(store: FileTreeStore, snapshotID: UUID) -> SnapshotSearchIndex {
        var entries: [FileSearchEntry] = []
        entries.reserveCapacity(store.nodeCount)
        for node in store.allNodes {
            entries.append(FileSearchEntry(
                id: node.id,
                lowercasedName: node.name.lowercased(),
                allocatedSize: node.allocatedSize,
                categoryKindID: FileKindClassifier.kindID(for: node, mode: .categories),
                typeKindID: FileKindClassifier.kindID(for: node, mode: .types),
                isKindCountable: FileKindClassifier.isKindCountable(node),
                lastModified: node.lastModified
            ))
        }
        entries.sort { $0.allocatedSize > $1.allocatedSize }
        return SnapshotSearchIndex(snapshotID: snapshotID, rootID: store.rootID, entries: entries)
    }
}

/// Owns the per-snapshot index: builds it once off the main actor on first
/// use and hands the same build to concurrent callers. The model invalidates
/// it whenever the displayed snapshot changes; callers must still re-check
/// the snapshot ID after awaiting, since a stale build can land late.
@MainActor
final class SearchIndexService {
    private var buildTask: Task<SnapshotSearchIndex, Never>?
    private var builtSnapshotID: UUID?

    /// The displayed tree changed: the cached index holds dead node IDs.
    func invalidate() {
        buildTask = nil
        builtSnapshotID = nil
    }

    func index(for snapshot: ScanSnapshot) async -> SnapshotSearchIndex {
        if builtSnapshotID == snapshot.id, let buildTask {
            return await buildTask.value
        }
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
final class SearchDebouncer {
    static let interval: Duration = .milliseconds(180)

    private var task: Task<Void, Never>?

    func schedule(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task {
            guard (try? await Task.sleep(for: Self.interval)) != nil else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
