import Foundation
import Testing
@testable import NeodiskKit

/// Proves the two concurrency assumptions Stage 2's parallel scanning rests
/// on: two scans of different targets driven through ONE shared
/// `IncrementalScanService` don't corrupt each other's trees, and two targets
/// saving/loading through one `ScanSnapshotCache` at once stay isolated.
@Suite("ConcurrentScanSafety", .serialized)
struct ConcurrentScanSafetyTests {
    private func makeTree(_ name: String, files: [(String, Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "concurrent-scan-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (fileName, size) in files {
            try Data(repeating: 0x61, count: size).write(to: root.appending(path: fileName))
        }
        return root
    }

    private func finishedSnapshot(
        from stream: AsyncThrowingStream<ScanProgressEvent, Error>
    ) async throws -> ScanSnapshot? {
        var finished: ScanSnapshot?
        for try await event in stream {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return finished
    }

    /// Two different-target fresh scans run at the same time through one
    /// service instance and produce independent, uncontaminated trees.
    @Test func testConcurrentScansOfDifferentTargetsThroughOneServiceStayIsolated() async throws {
        let rootA = try makeTree("a", files: [("a1.bin", 4096), ("a2.bin", 2048)])
        let rootB = try makeTree("b", files: [("b1.bin", 8192)])
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let targetA = ScanTarget(url: rootA)
        let targetB = ScanTarget(url: rootB)

        // One shared service — the exact sharing the running app does.
        let service = IncrementalScanService()

        async let snapshotA = finishedSnapshot(from: service.scan(target: targetA, options: ScanOptions()))
        async let snapshotB = finishedSnapshot(from: service.scan(target: targetB, options: ScanOptions()))
        let resolvedA = try #require(await snapshotA)
        let resolvedB = try #require(await snapshotB)

        #expect(resolvedA.target.id == targetA.id)
        #expect(resolvedB.target.id == targetB.id)

        let namesA = Set(resolvedA.treeStore.allNodes.map(\.name))
        let namesB = Set(resolvedB.treeStore.allNodes.map(\.name))
        // Each tree holds only its own files — no cross-contamination.
        #expect(namesA.contains("a1.bin"))
        #expect(namesA.contains("a2.bin"))
        #expect(!namesA.contains("b1.bin"))
        #expect(namesB.contains("b1.bin"))
        #expect(!namesB.contains("a1.bin"))

        // Sizes are independent and correct.
        #expect(resolvedA.treeStore.root.logicalSize == 4096 + 2048)
        #expect(resolvedB.treeStore.root.logicalSize == 8192)
    }

    /// Two targets saving and loading through one cache actor at the same time
    /// keep their own latest slots — no shared temp file or rotation bleed.
    @Test func testConcurrentTwoTargetSaveAndLoadStayIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "concurrent-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScanSnapshotCache(directoryURL: directory, isLoggingEnabled: false)

        let targetA = makeTestTarget("/concurrent/cache-a")
        let targetB = makeTestTarget("/concurrent/cache-b")
        let snapshotA = snapshot(for: targetA, fileName: "a.txt", size: 11)
        let snapshotB = snapshot(for: targetB, fileName: "b.txt", size: 22)

        // Save both concurrently.
        async let saveA: Void = { _ = try? await cache.save(snapshotA) }()
        async let saveB: Void = { _ = try? await cache.save(snapshotB) }()
        _ = await (saveA, saveB)

        // Load both concurrently; each returns its own tree.
        async let loadedA = cache.loadSnapshot(for: targetA)
        async let loadedB = cache.loadSnapshot(for: targetB)
        let resolvedA = try #require(await loadedA)
        let resolvedB = try #require(await loadedB)

        #expect(resolvedA.target.id == targetA.id)
        #expect(resolvedB.target.id == targetB.id)
        #expect(resolvedA.treeStore.allNodes.contains { $0.name == "a.txt" })
        #expect(resolvedB.treeStore.allNodes.contains { $0.name == "b.txt" })
        #expect(!resolvedA.treeStore.allNodes.contains { $0.name == "b.txt" })
        #expect(resolvedA.treeStore.root.logicalSize == 11)
        #expect(resolvedB.treeStore.root.logicalSize == 22)
    }

    private func snapshot(for target: ScanTarget, fileName: String, size: Int64) -> ScanSnapshot {
        let file = makeTestFileNode(id: target.id + "/" + fileName, name: fileName, size: size)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        return makeTestSnapshot(target: target, root: root, store: store)
    }
}
