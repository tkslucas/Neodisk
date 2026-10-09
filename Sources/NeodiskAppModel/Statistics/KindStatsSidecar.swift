//
//  KindStatsSidecar.swift
//  Neodisk
//
//  The persisted form of a snapshot's kind statistics, stored through the
//  snapshot cache's auxiliary-data slot. Restoring a snapshot rebuilds its
//  kind catalog from these aggregates in milliseconds instead of an
//  O(nodes) classification pass — so the first render is colored, not gray.
//

import Foundation
import NeodiskKit

package nonisolated struct KindStatsSidecar: Codable, Sendable {
    /// Identity of the snapshot these stats describe. A sidecar that does
    /// not match the decoded snapshot (another process rewrote the cache,
    /// or a failed save left it behind) is ignored.
    package let targetPath: String
    package let finishedAt: Date?
    package let nodeCount: Int

    package let categories: [PersistedKindStat]
    package let types: [PersistedKindStat]

    package nonisolated func stats(for mode: FileKindDisplayMode) -> [PersistedKindStat] {
        switch mode {
        case .categories: return categories
        case .types: return types
        }
    }

    /// Whether these stats describe the given snapshot. Dates go through
    /// JSON with sub-second loss, so equality is tolerant.
    package nonisolated func matches(_ snapshot: ScanSnapshot) -> Bool {
        guard snapshot.isComplete,
              targetPath == snapshot.target.id,
              nodeCount == snapshot.treeStore.nodeCount else {
            return false
        }
        switch (finishedAt, snapshot.finishedAt) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 1
        default:
            return false
        }
    }

    package nonisolated static func make(for snapshot: ScanSnapshot) -> KindStatsSidecar {
        let aggregated = FileKindCatalog.aggregateBothModes(from: snapshot.treeStore)
        return KindStatsSidecar(
            targetPath: snapshot.target.id,
            finishedAt: snapshot.finishedAt,
            nodeCount: snapshot.treeStore.nodeCount,
            categories: aggregated.categories,
            types: aggregated.types
        )
    }

    package nonisolated func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    package nonisolated static func decoding(_ data: Data) -> KindStatsSidecar? {
        try? JSONDecoder().decode(KindStatsSidecar.self, from: data)
    }
}
