// Persisted kind statistics, so a restored snapshot's first render is colored in milliseconds, not gray.

import Foundation
import NeodiskKit

package nonisolated struct KindStatsSidecar: Codable, Sendable {
    /// A sidecar that doesn't match the decoded snapshot (rewritten cache, failed save) is ignored.
    package let targetPath: String
    package let finishedAt: Date?
    package let nodeCount: Int
    /// `FileCategoryRules.fingerprint`; nil in sidecars from before categories could change.
    package let categoryRules: String?

    package let categories: [PersistedKindStat]
    package let types: [PersistedKindStat]

    package nonisolated func stats(for mode: FileKindDisplayMode) -> [PersistedKindStat] {
        switch mode {
        case .categories: return categories
        case .types: return types
        }
    }

    /// Dates lose sub-second precision through JSON, so equality is tolerant.
    package nonisolated func matches(_ snapshot: ScanSnapshot) -> Bool {
        guard snapshot.isComplete,
              categoryRules == FileCategoryRules.current.fingerprint,
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
        let rules = FileCategoryRules.current
        let aggregated = FileKindCatalog.aggregateBothModes(from: snapshot.treeStore, rules: rules)
        return KindStatsSidecar(
            targetPath: snapshot.target.id,
            finishedAt: snapshot.finishedAt,
            nodeCount: snapshot.treeStore.nodeCount,
            categoryRules: rules.fingerprint,
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
