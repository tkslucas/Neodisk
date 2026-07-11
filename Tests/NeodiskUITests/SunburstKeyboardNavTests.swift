import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Sunburst arrow-key resolution: sibling order follows the tree's display
/// order (largest first, the chart's angular order) and every move is
/// restricted to rendered segments.
struct SunburstKeyboardNavTests {
    private struct Fixture {
        let store: FileTreeStore
        let root: FileNodeRecord
        let docs: FileNodeRecord
        let media: FileNodeRecord
        let tiny: FileNodeRecord
        let bigDoc: FileNodeRecord
        let smallDoc: FileNodeRecord
    }

    /// root ─┬─ docs (110) ─┬─ big.pdf (100)
    ///        │             └─ small.pdf (10)
    ///        ├─ media (60) ── movie.mp4 (60)
    ///        └─ tiny.txt (1)   (pooled away: not rendered)
    private func makeFixture() -> Fixture {
        let bigDoc = makeTestFileNode(id: "/root/docs/big.pdf", name: "big.pdf", size: 100)
        let smallDoc = makeTestFileNode(id: "/root/docs/small.pdf", name: "small.pdf", size: 10)
        let docs = makeTestDirectoryNode(id: "/root/docs", name: "docs", children: [bigDoc, smallDoc])
        let movie = makeTestFileNode(id: "/root/media/movie.mp4", name: "movie.mp4", size: 60)
        let media = makeTestDirectoryNode(id: "/root/media", name: "media", children: [movie])
        let tiny = makeTestFileNode(id: "/root/tiny.txt", name: "tiny.txt", size: 1)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [docs, media, tiny])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [docs, media, tiny],
                docs.id: [bigDoc, smallDoc],
                media.id: [movie],
            ]
        )
        return Fixture(store: store, root: root, docs: docs, media: media, tiny: tiny, bigDoc: bigDoc, smallDoc: smallDoc)
    }

    /// Everything except tiny.txt renders (it pooled into an aggregate).
    private func isRendered(_ fixture: Fixture) -> (String) -> Bool {
        let rendered: Set<String> = [
            fixture.docs.id, fixture.media.id,
            fixture.bigDoc.id, fixture.smallDoc.id,
            "/root/media/movie.mp4",
        ]
        return { rendered.contains($0) }
    }

    private func target(
        _ fixture: Fixture,
        from selected: String?,
        _ direction: SunburstKeyboardNav.Direction
    ) -> String? {
        SunburstKeyboardNav.target(
            from: selected,
            direction: direction,
            rootID: fixture.root.id,
            store: fixture.store,
            isRendered: isRendered(fixture)
        )
    }

    @Test func testNoSelectionAnchorsOnLargestRenderedChildOfRoot() {
        let fixture = makeFixture()
        for direction: SunburstKeyboardNav.Direction in [.previousSibling, .nextSibling, .parent, .largestChild] {
            #expect(target(fixture, from: nil, direction) == fixture.docs.id)
        }
    }

    @Test func testUnrenderedSelectionReanchors() {
        let fixture = makeFixture()
        // tiny.txt exists in the tree but pooled away — arrows re-anchor.
        #expect(target(fixture, from: fixture.tiny.id, .nextSibling) == fixture.docs.id)
    }

    @Test func testUnknownSelectionReanchors() {
        let fixture = makeFixture()
        #expect(target(fixture, from: "/nowhere", .parent) == fixture.docs.id)
    }

    @Test func testNextSiblingFollowsDisplayOrder() {
        let fixture = makeFixture()
        #expect(target(fixture, from: fixture.docs.id, .nextSibling) == fixture.media.id)
        #expect(target(fixture, from: fixture.media.id, .previousSibling) == fixture.docs.id)
    }

    @Test func testSiblingEdgesStop() {
        let fixture = makeFixture()
        // docs is the first rendered sibling, media the last (tiny pooled).
        #expect(target(fixture, from: fixture.docs.id, .previousSibling) == nil)
        #expect(target(fixture, from: fixture.media.id, .nextSibling) == nil)
    }

    @Test func testParentStopsAtRootRing() {
        let fixture = makeFixture()
        // The center hole is the root itself, not a selectable segment.
        #expect(target(fixture, from: fixture.docs.id, .parent) == nil)
        #expect(target(fixture, from: fixture.bigDoc.id, .parent) == fixture.docs.id)
    }

    @Test func testLargestChildDescends() {
        let fixture = makeFixture()
        #expect(target(fixture, from: fixture.docs.id, .largestChild) == fixture.bigDoc.id)
        // Files have no children.
        #expect(target(fixture, from: fixture.bigDoc.id, .largestChild) == nil)
    }

    @Test func testDrilledRootScopesNavigation() {
        let fixture = makeFixture()
        // Drilled into docs: ↑ from its children stops (docs is the center).
        let result = SunburstKeyboardNav.target(
            from: fixture.bigDoc.id,
            direction: .parent,
            rootID: fixture.docs.id,
            store: fixture.store,
            isRendered: isRendered(fixture)
        )
        #expect(result == nil)
    }
}
