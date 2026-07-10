import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The benches load a real cached snapshot; `NEODISK_KIND_BENCH` holds the
/// scanned path to bench (e.g. `NEODISK_KIND_BENCH=$HOME`).
private func benchTarget() -> ScanTarget? {
    guard let path = ProcessInfo.processInfo.environment["NEODISK_KIND_BENCH"],
          path.hasPrefix("/") else { return nil }
    return ScanTarget(
        id: path,
        url: URL(filePath: path, directoryHint: .isDirectory),
        displayName: URL(filePath: path).lastPathComponent,
        kind: .folder
    )
}

@Suite struct KindCatalogBenchTests {
    @Test(.enabled(if: benchTarget() != nil))
    func benchKindCatalogBuild() async throws {
        let cache = ScanSnapshotCache(isLoggingEnabled: false)
        let target = try #require(benchTarget())
        let snapshot = try #require(await cache.loadSnapshot(for: target))
        let clock = ContinuousClock()
        for mode in [FileKindDisplayMode.categories, .types] {
            var catalog = FileKindCatalog.empty
            let elapsed = clock.measure {
                catalog = FileKindCatalog.build(from: snapshot.treeStore, mode: mode)
            }
            print("KINDBENCH \(mode): \(elapsed) — \(catalog.stats.count) kinds")
        }
    }
}

@Suite struct SearchBenchTests {
    @Test(.enabled(if: benchTarget() != nil))
    func benchEntireScanFuzzySearch() async throws {
        let cache = ScanSnapshotCache(isLoggingEnabled: false)
        let target = try #require(benchTarget())
        let snapshot = try #require(await cache.loadSnapshot(for: target))
        let clock = ContinuousClock()

        var entries: [FileSearchEntry] = []
        let indexTime = clock.measure {
            entries.reserveCapacity(snapshot.treeStore.nodeCount)
            for node in snapshot.treeStore.allNodes {
                entries.append(FileSearchEntry(
                    id: node.id,
                    lowercasedName: node.name.lowercased(),
                    allocatedSize: node.allocatedSize
                ))
            }
        }
        print("SEARCHBENCH index build: \(indexTime) — \(entries.count) entries")

        for query in ["node", "pkg", "screenshot 2026"] {
            var result: (ids: [String], totalMatches: Int) = ([], 0)
            let elapsed = clock.measure {
                result = FuzzyMatcher.topMatches(query: query, entries: entries, limit: 100)
            }
            print("SEARCHBENCH \"\(query)\": \(elapsed) — \(result.totalMatches) matches")
        }
    }
}
