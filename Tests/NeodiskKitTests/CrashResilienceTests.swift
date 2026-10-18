import Foundation
import Testing
@testable import NeodiskKit

@Suite struct CrashResilienceTests {
    @Test func storeWithMissingRootDegradesToPlaceholder() {
        let orphan = makeTestFileNode(id: "/root/file.bin", name: "file.bin", size: 10)
        let store = FileTreeStore(
            rootID: "/missing",
            nodesByID: [orphan.id: orphan],
            childIDsByID: [:],
            parentIDByID: [:]
        )
        // Must not hit the rootID preconditionFailure.
        #expect(store.root.id == "/missing")
        #expect(store.root.allocatedSize == 0)
        #expect(store.root.isSynthetic)
        #expect(store.aggregateStats.totalAllocatedSize == 0)
        #expect(store.children(of: "/missing").isEmpty)
    }

    @Test func addingClampedSaturatesInsteadOfTrapping() {
        #expect(Int64.max.addingClamped(1) == Int64.max)
        #expect(Int64.max.addingClamped(Int64.max) == Int64.max)
        #expect(Int64.min.addingClamped(-1) == Int64.min)
        #expect(Int64(5).addingClamped(7) == 12)
        #expect(Int64.max.addingClamped(-3) == Int64.max - 3)
    }

    @Test func directoryTotalsSaturateOnPathologicalChildSizes() {
        let a = makeTestFileNode(id: "/root/a", name: "a", size: .max)
        let b = makeTestFileNode(id: "/root/b", name: "b", size: .max)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a, b])
        #expect(root.allocatedSize == .max)
    }
}
