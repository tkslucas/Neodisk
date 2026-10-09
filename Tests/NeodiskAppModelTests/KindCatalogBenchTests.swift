import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

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

    /// Synthetic whole-scan index (`NEODISK_SEARCH_BENCH=<entries>`, e.g.
    /// 1000000): the bounded top-k heap against the old collect-and-sort
    /// ranking, same queries, same results. Broad queries are where the
    /// full sort hurt — every match was sorted to keep 100.
    @Test(.enabled(if: syntheticSearchBenchCount() != nil))
    func benchSyntheticTopMatches() throws {
        let count = try #require(syntheticSearchBenchCount())
        var rng = SeededTestGenerator(seed: 42)
        let stems = [
            "node_modules", "index", "readme", "package", "screenshot 2026-03-14",
            "img_4821", "report-final", "library", "cache", "photo", "notes",
            "build", "main", "config", "data", "video", "backup", "archive",
        ]
        let extensions = ["js", "json", "md", "png", "jpg", "txt", "swift", "mov", "zip", ""]
        let entries = (0..<count).map { index in
            let stem = stems.randomElement(using: &rng)!
            let ext = extensions.randomElement(using: &rng)!
            let name = "\(stem)\(Int.random(in: 0..<1_000, using: &rng))" + (ext.isEmpty ? "" : ".\(ext)")
            return FileSearchEntry(
                id: "/bench/\(index)/\(name)", lowercasedName: name,
                allocatedSize: Int64.random(in: 0..<1_000_000, using: &rng)
            )
        }
        let clock = ContinuousClock()
        // Warm-up so neither side pays first-touch costs.
        _ = FuzzyMatcher.topMatches(query: "zzzz", entries: entries, limit: 100)
        for query in ["e", "a", "node", "pkg", "screenshot 2026", "img"] {
            var before: (ids: [String], totalMatches: Int) = ([], 0)
            var after: (ids: [String], totalMatches: Int) = ([], 0)
            var beforeTimes: [Duration] = []
            var afterTimes: [Duration] = []
            for _ in 0..<3 {
                beforeTimes.append(clock.measure {
                    before = referenceTopMatches(query: query, entries: entries, limit: 100)
                })
                afterTimes.append(clock.measure {
                    after = FuzzyMatcher.topMatches(query: query, entries: entries, limit: 100)
                })
            }
            #expect(after.ids == before.ids)
            #expect(after.totalMatches == before.totalMatches)
            print("SEARCHBENCH synthetic \(count) \"\(query)\": sort \(beforeTimes.min()!) → heap \(afterTimes.min()!) — \(after.totalMatches) matches")
        }
    }
}

private func syntheticSearchBenchCount() -> Int? {
    ProcessInfo.processInfo.environment["NEODISK_SEARCH_BENCH"].flatMap(Int.init)
}
