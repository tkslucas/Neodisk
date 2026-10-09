import Testing
import Foundation
@testable import NeodiskKit

/// The scan hot path's string shortcuts must agree with the slow forms they
/// replace, and its scheduling pieces must keep slow work from blocking the rest.
@Suite struct ScanHotPathTests {
    @Test func lexicallyNormalPathsAreTheirOwnStandardization() {
        let normal = ["/", "/a", "/Users/me/Library", "/a/.hidden", "/a/...", "/a/b..c", "/a/.x./y", "/a b/c"]
        for path in normal {
            #expect(ScanExclusionMatcher.isLexicallyNormal(path), "\(path)")
            #expect(URL(fileURLWithPath: path).standardized.path == path, "\(path)")
        }
        let notNormal = ["", "a/b", "/a/", "//a", "/a//b", "/a/./b", "/a/../b", "/a/.", "/a/..", "/.", "/.."]
        for path in notNormal {
            #expect(!ScanExclusionMatcher.isLexicallyNormal(path), "\(path)")
        }
    }

    @Test func scanPathMatchesStandardizedPath() {
        let matcher = ScanExclusionMatcher(patterns: [], rootPath: "/Users/me", includeCloudStorage: false)
        for path in ["/Users/me/a", "/Users/me/a/../b", "/Users/me/./c", "/Users/me/d/"] {
            let url = URL(fileURLWithPath: path)
            #expect(matcher.scanPath(of: url) == url.standardized.path, "\(path)")
        }
    }

    @Test func cloudRootIsExcludedByNameAndOtherChildrenAreNot() {
        let matcher = ScanExclusionMatcher(patterns: [], rootPath: "/Users", includeCloudStorage: false)
        #expect(matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "CloudStorage", isDirectory: true))
        #expect(matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "Mobile Documents", isDirectory: true))
        #expect(!matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "Caches", isDirectory: true))
        #expect(!matcher.excludes(normalizedParentPath: "/Users/me/Documents", childName: "CloudStorage.txt", isDirectory: false))
    }

    #if canImport(Darwin)
    @Test func protectedContainersCoverOtherAppsContainers() {
        #expect(ProtectedContainers.contains("/Users/me/Library/Containers/com.app/Data"))
        #expect(ProtectedContainers.contains("/Users/me/Library/Group Containers/group.x/y"))
        #expect(!ProtectedContainers.contains("/Users/me/Library/Containers"))
        #expect(!ProtectedContainers.contains("/Users/me/Library/Caches/Containers/x"))
        #expect(ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library/Containers"))
        #expect(ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library/Group Containers"))
        #expect(!ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library"))
    }
    #endif

    @Test func listingCacheHandsEachListingOutOnceWithinItsBudget() {
        let cache = DirectoryListingCache(maximumEntryCount: 3)
        let child = BulkDirectoryChild(
            name: "a", metadata: nil, entryErrno: nil, isHidden: false, deviceID: nil, directoryMountStatus: 0
        )
        cache.store([child, child], forDirectory: "/x")
        cache.store([child, child], forDirectory: "/y")
        #expect(cache.take(forDirectory: "/y") == nil)
        #expect(cache.take(forDirectory: "/x")?.count == 2)
        #expect(cache.take(forDirectory: "/x") == nil)
        cache.store([child, child, child], forDirectory: "/y")
        #expect(cache.take(forDirectory: "/y")?.count == 3)
    }

    @Test func slowDirectoryReadDoesNotHoldQueuedReads() async throws {
        // The slow read holds its thread until every queued read is done; if
        // queued reads waited behind it, it would time out instead.
        let executor = DirectoryIOExecutor(workerCount: 2)
        let fastReadsDone = DispatchSemaphore(value: 0)
        let slow = Task {
            try await executor.run { _, _ in
                fastReadsDone.wait(timeout: .now() + 10) == .success
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await executor.run { _, _ in 1 } }
            }
            try await group.waitForAll()
        }
        fastReadsDone.signal()
        #expect(try await slow.value)
    }
}
