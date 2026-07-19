//
//  SunburstGeometryTests.swift
//  Neodisk
//
//  Sunburst geometry suite, plus Neodisk-specific
//  coverage for the free-space segment and layout-time kind/age coloring.
//

import SunburstCore
import CoreGraphics
import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct SunburstGeometryTests {
    @Test func topLevelSegmentsCoverFullCircle() {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 1),
        ]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle - segment.startAngle)
        }

        #expect(segments.count == 2)
        #expect(abs(totalRadians - .pi * 2) < 0.0001)
    }

    @Test func mixedZeroByteChildrenDoNotOverflowParentArc() throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 10),
            makeTestFileNode(id: "/root/empty-1", name: "empty-1", size: 0),
            makeTestFileNode(id: "/root/empty-2", name: "empty-2", size: 0),
        ]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let totalRadians = segments.reduce(0.0) { partialResult, segment in
            partialResult + (segment.endAngle - segment.startAngle)
        }
        let lastSegment = try #require(segments.last)

        #expect(segments.count == 3)
        #expect(abs(totalRadians - .pi * 2) < 0.0001)
        #expect(lastSegment.endAngle <= .pi * 2 + 0.0001)
    }

    @Test func smallItemsCollapseIntoAggregateSegment() throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 100),
            makeTestFileNode(id: "/root/tiny-1", name: "tiny-1", size: 1),
            makeTestFileNode(id: "/root/tiny-2", name: "tiny-2", size: 1),
            makeTestFileNode(id: "/root/tiny-3", name: "tiny-3", size: 1),
        ]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, minimumAngle: .pi / 2
        )
        let aggregate = try #require(segments.first { $0.isAggregate })

        #expect(aggregate.nodeID == nil)
        #expect(aggregate.label == "Smaller Items")
        #expect(aggregate.totalSize == 3)
        #expect(aggregate.colorToken.role == .aggregate)
        #expect(aggregate.parentFolderID == "/root")
        #expect(aggregate.itemCount == 3)
    }

    @Test func expandedAggregateLaysOutSmallItemsIndividually() throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 100),
            makeTestFileNode(id: "/root/tiny-1", name: "tiny-1", size: 1),
            makeTestFileNode(id: "/root/tiny-2", name: "tiny-2", size: 1),
            makeTestFileNode(id: "/root/tiny-3", name: "tiny-3", size: 1),
        ]
        let store = makeGeometryStore(children: children)

        // Same tree as the pooling test, but with the folder's pool opened:
        // every tiny child gets its own (hairline) segment.
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, minimumAngle: .pi / 2,
            expandedAggregateIDs: ["/root"]
        )

        #expect(!segments.contains { $0.isAggregate })
        let ids = segments.compactMap(\.nodeID)
        #expect(ids.contains("/root/tiny-1"))
        #expect(ids.contains("/root/tiny-2"))
        #expect(ids.contains("/root/tiny-3"))
    }

    @Test func hitTesterReturnsExpectedSegment() throws {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 1),
            makeTestFileNode(id: "/root/b", name: "b", size: 1),
        ]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let firstSegment = try #require(segments.first)
        let size = CGSize(width: 300, height: 300)
        let hitPoint = pointInside(segment: firstSegment, in: size)

        #expect(SunburstHitTester.segment(at: hitPoint, in: size, segments: segments)?.id == firstSegment.id)
    }

    @Test func centerHitTesterMatchesLayoutHole() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 1)]
        let store = makeGeometryStore(children: children)
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let firstSegment = try #require(segments.first)
        let size = CGSize(width: 300, height: 300)

        #expect(firstSegment.innerRadius == SunburstLayout.centerRadius)
        #expect(SunburstCenterHitTester.contains(point: CGPoint(x: 150, y: 150), in: size))
        #expect(SunburstCenterHitTester.contains(point: pointInRing(radius: 0.21, in: size), in: size))
        #expect(!SunburstCenterHitTester.contains(point: pointInRing(radius: 0.23, in: size), in: size))
        #expect(SunburstHitTester.segment(at: CGPoint(x: 150, y: 150), in: size, segments: segments) == nil)
    }

    @Test func hitTestIndexFindsSegmentInMatchingRing() {
        let size = CGSize(width: 300, height: 300)
        let innerRing = makeSegment(id: "inner", innerRadius: 0.1, outerRadius: 0.3, depth: 0)
        let outerRing = makeSegment(id: "outer", innerRadius: 0.45, outerRadius: 0.8, depth: 1)
        let index = SunburstHitTestIndex(segments: [innerRing, outerRing])

        #expect(index.segment(at: pointInRing(radius: 0.2, in: size), in: size)?.id == innerRing.id)
        #expect(index.segment(at: pointInRing(radius: 0.6, in: size), in: size)?.id == outerRing.id)
        #expect(index.segment(at: pointInRing(radius: 0.38, in: size), in: size) == nil)
    }

    @Test func ringGapBelongsToTheArcItHangsOff() throws {
        // Real layout radii: ring 0 arc ends ringGap short of ring 1's inner
        // edge. The gap is cosmetic — hovering it must hit the ring 0 arc,
        // not report a dead zone (which would flicker the legend preview
        // when sliding from a folder into its subfolder).
        let nested = makeTestFileNode(id: "/root/a/child", name: "child", size: 5)
        let branch = makeTestDirectoryNode(id: "/root/a", name: "a", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branch])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [branch],
            "/root/a": [nested],
        ])
        let size = CGSize(width: 300, height: 300)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 2)
        let parent = try #require(segments.first { $0.nodeID == "/root/a" })
        let gapRadius = parent.outerRadius + (SunburstLayout.ringGap / 2)

        let hit = SunburstHitTester.segment(
            at: pointInRing(radius: gapRadius, in: size),
            in: size,
            segments: segments
        )
        #expect(hit?.id == parent.id)
    }

    @Test func hitTestRoundtripsEveryTaperedRingToItsDepth() throws {
        // A four-deep chain: rings taper outward, so their radial bands are
        // uneven. Hitting each drawn arc at its own mid-radius must land back
        // on a segment of that depth — the hit-test bands and the drawn bands
        // share the one metrics source, so they can never drift apart.
        let leaf = makeTestFileNode(id: "/root/a/b/c/leaf", name: "leaf", size: 5)
        let c = makeTestDirectoryNode(id: "/root/a/b/c", name: "c", children: [leaf])
        let b = makeTestDirectoryNode(id: "/root/a/b", name: "b", children: [c])
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [b])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [a],
            "/root/a": [b],
            "/root/a/b": [c],
            "/root/a/b/c": [leaf],
        ])
        let size = CGSize(width: 400, height: 400)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 4)
        #expect(Set(segments.map(\.depth)) == [0, 1, 2, 3])

        for segment in segments {
            let hit = SunburstHitTester.segment(
                at: pointInside(segment: segment, in: size),
                in: size,
                segments: segments
            )
            #expect(hit?.depth == segment.depth)
            #expect(hit?.id == segment.id)
        }
    }

    @Test func hitTestIndexFindsAngleInUnsortedRing() {
        let size = CGSize(width: 300, height: 300)
        let first = makeSegment(id: "first", startAngle: 0, endAngle: .pi, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let second = makeSegment(id: "second", startAngle: .pi, endAngle: .pi * 2, innerRadius: 0.1, outerRadius: 0.8, depth: 0)
        let index = SunburstHitTestIndex(segments: [second, first])

        #expect(index.segment(at: pointInside(segment: second, in: size), in: size)?.id == second.id)
    }

    @Test func topLevelSiblingColorTokensUseDistinctBranches() {
        let children = [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 2),
            makeTestFileNode(id: "/root/c", name: "c", size: 1),
        ]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let tokens = segments.map(\.colorToken)

        #expect(tokens.map(\.branchID) == ["/root/a", "/root/b", "/root/c"])
        #expect(tokens.map(\.branchIndex) == [0, 1, 2])
        #expect(tokens.map(\.branchCount) == [3, 3, 3])
        #expect(Set(tokens.map { SunburstColorResolver.components(for: $0) }).count == 3)
    }

    @Test func branchColorStaysStableWhenSiblingSortOrderChanges() throws {
        let firstStore = makeGeometryStore(children: [
            makeTestFileNode(id: "/root/a", name: "a", size: 3),
            makeTestFileNode(id: "/root/b", name: "b", size: 2),
        ])
        let secondStore = makeGeometryStore(children: [
            makeTestFileNode(id: "/root/a", name: "a", size: 1),
            makeTestFileNode(id: "/root/b", name: "b", size: 4),
        ])

        let firstSegment = try #require(
            SunburstLayout.segments(in: firstStore, rootID: "/root", depthLimit: 1)
                .first { $0.nodeID == "/root/a" }
        )
        let secondSegment = try #require(
            SunburstLayout.segments(in: secondStore, rootID: "/root", depthLimit: 1)
                .first { $0.nodeID == "/root/a" }
        )

        #expect(firstSegment.colorToken.branchIndex != secondSegment.colorToken.branchIndex)
        #expect(
            SunburstColorResolver.components(for: firstSegment.colorToken)
                == SunburstColorResolver.components(for: secondSegment.colorToken)
        )
    }

    @Test func childColorTokensKeepBranchFamilyButVaryBySibling() {
        // Directory siblings: files are uniformly gray in branch mode, so
        // per-sibling hue variation only applies to folders.
        let fileOne = makeTestFileNode(id: "/root/a/one/f", name: "f", size: 3)
        let fileTwo = makeTestFileNode(id: "/root/a/two/f", name: "f", size: 2)
        let fileThree = makeTestFileNode(id: "/root/a/three/f", name: "f", size: 1)
        let children = [
            makeTestDirectoryNode(id: "/root/a/one", name: "one", children: [fileOne]),
            makeTestDirectoryNode(id: "/root/a/two", name: "two", children: [fileTwo]),
            makeTestDirectoryNode(id: "/root/a/three", name: "three", children: [fileThree]),
        ]
        let branch = makeTestDirectoryNode(id: "/root/a", name: "a", children: children)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branch])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [branch],
            "/root/a": children,
            "/root/a/one": [fileOne],
            "/root/a/two": [fileTwo],
            "/root/a/three": [fileThree],
        ])

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 2)
        let childTokens = segments
            .filter { $0.depth == 1 }
            .map(\.colorToken)

        #expect(childTokens.map(\.branchID) == Array(repeating: "/root/a", count: 3))
        #expect(childTokens.map(\.siblingIndex) == [0, 1, 2])
        #expect(childTokens.map(\.siblingCount) == [3, 3, 3])
        #expect(Set(childTokens.map { SunburstColorResolver.components(for: $0) }).count == 3)
    }

    @Test func focusedSubtreeKeepsScanRootBranchFamily() throws {
        let nestedChildren = [
            makeTestFileNode(id: "/root/a/child-1", name: "child-1", size: 2),
            makeTestFileNode(id: "/root/a/child-2", name: "child-2", size: 1),
        ]
        let branchA = makeTestDirectoryNode(id: "/root/a", name: "a", children: nestedChildren)
        let branchB = makeTestFileNode(id: "/root/b", name: "b", size: 1)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branchA, branchB])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [branchA, branchB],
            "/root/a": nestedChildren,
        ])

        let rootSegments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let branchToken = try #require(rootSegments.first { $0.nodeID == "/root/a" }).colorToken
        let focusedSegments = SunburstLayout.segments(in: store, rootID: "/root/a", depthLimit: 1)

        #expect(focusedSegments.map(\.colorToken.branchID) == ["/root/a", "/root/a"])
        #expect(focusedSegments.map(\.colorToken.branchIndex) == [branchToken.branchIndex, branchToken.branchIndex])
        #expect(focusedSegments.map(\.colorToken.branchCount) == [branchToken.branchCount, branchToken.branchCount])
    }

    @Test func layoutStopsWhenCancellationCheckThrows() {
        let children = (0..<100).map { index in
            makeTestFileNode(id: "/root/file-\(index)", name: "file-\(index)", size: 1)
        }
        let store = makeGeometryStore(children: children)
        var cancellationChecks = 0

        #expect(throws: CancellationError.self) {
            try SunburstLayout.segments(
                in: store,
                rootID: "/root",
                depthLimit: 2,
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 4 {
                        throw CancellationError()
                    }
                }
            )
        }
        #expect(cancellationChecks == 4)
    }

    // MARK: - Free space (Neodisk-specific)

    @Test func freeSpaceAppendsOneTopRingSegment() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 300)]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3, freeSpaceBytes: 100
        )
        let freeSegment = try #require(segments.first { $0.isFreeSpace })
        let fileSegment = try #require(segments.first { $0.nodeID == "/root/a" })

        // 300 allocated + 100 free: the file gets 3/4 of the circle, free
        // space the trailing 1/4 — always on the top ring, never recursed.
        #expect(abs(fileSegment.endAngle - .pi * 1.5) < 0.0001)
        #expect(abs(freeSegment.startAngle - .pi * 1.5) < 0.0001)
        #expect(abs(freeSegment.endAngle - .pi * 2) < 0.0001)
        #expect(freeSegment.nodeID == nil)
        #expect(freeSegment.depth == 0)
        #expect(freeSegment.totalSize == 100)
        #expect(freeSegment.colorToken.role == .freeSpace)
        #expect(segments.count { $0.isFreeSpace } == 1)
    }

    @Test func withoutFreeSpaceNoSyntheticSegmentAppears() {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 300)]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)

        #expect(!segments.contains { $0.isFreeSpace })
        #expect(!segments.contains { $0.isHiddenSpace })
    }

    // MARK: - Hidden space (Neodisk-specific)

    @Test func hiddenSpaceAppendsOneTopRingSegmentBeforeFreeSpace() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 200)]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3,
            freeSpaceBytes: 100, hiddenSpaceBytes: 100
        )
        let fileSegment = try #require(segments.first { $0.nodeID == "/root/a" })
        let hiddenSegment = try #require(segments.first { $0.isHiddenSpace })
        let freeSegment = try #require(segments.first { $0.isFreeSpace })

        // 200 allocated + 100 hidden + 100 free: half the circle for the
        // file, then the hidden quarter, then the trailing free quarter —
        // both synthetic arcs on the top ring, never recursed.
        #expect(abs(fileSegment.endAngle - .pi) < 0.0001)
        #expect(abs(hiddenSegment.startAngle - .pi) < 0.0001)
        #expect(abs(hiddenSegment.endAngle - .pi * 1.5) < 0.0001)
        #expect(abs(freeSegment.startAngle - .pi * 1.5) < 0.0001)
        #expect(abs(freeSegment.endAngle - .pi * 2) < 0.0001)
        #expect(hiddenSegment.nodeID == nil)
        #expect(hiddenSegment.depth == 0)
        #expect(hiddenSegment.totalSize == 100)
        #expect(hiddenSegment.colorToken.role == .hiddenSpace)
        #expect(!hiddenSegment.isFreeSpace)
        #expect(segments.count { $0.isHiddenSpace } == 1)
    }

    @Test func hiddenSpaceWithoutFreeSpaceFillsTheTrailingArc() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 300)]
        let store = makeGeometryStore(children: children)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, hiddenSpaceBytes: 100
        )
        let hiddenSegment = try #require(segments.first { $0.isHiddenSpace })

        #expect(abs(hiddenSegment.startAngle - .pi * 1.5) < 0.0001)
        #expect(abs(hiddenSegment.endAngle - .pi * 2) < 0.0001)
        #expect(!segments.contains { $0.isFreeSpace })
    }

    // MARK: - Layout-time coloring (Neodisk-specific)

    @Test func branchModeResolvesTokenFillsAtLayoutTime() throws {
        let file = makeTestFileNode(id: "/root/a.mov", name: "a.mov", size: 10)
        let nested = makeTestFileNode(id: "/root/sub/b.mov", name: "b.mov", size: 20)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file, sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [file, sub],
            "/root/sub": [nested],
        ])

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 2,
            style: SunburstColorStyle(mode: .branch)
        )

        let dirSegment = try #require(segments.first { $0.nodeID == sub.id })
        let fileSegment = try #require(segments.first { $0.nodeID == file.id })
        #expect(dirSegment.fillRGB == SunburstColorResolver.rgb(for: dirSegment.colorToken))
        #expect(fileSegment.fillRGB == SunburstColorResolver.rgb(for: fileSegment.colorToken))
    }

    @Test func branchModeDrawsFilesGrayAndFoldersColored() throws {
        let file = makeTestFileNode(id: "/root/a.mov", name: "a.mov", size: 10)
        let nested = makeTestFileNode(id: "/root/sub/b.mov", name: "b.mov", size: 20)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file, sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [file, sub],
            "/root/sub": [nested],
        ])

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 2,
            style: SunburstColorStyle(mode: .branch)
        )

        let fileSegment = try #require(segments.first { $0.nodeID == file.id })
        let nestedSegment = try #require(segments.first { $0.nodeID == nested.id })
        let dirSegment = try #require(segments.first { $0.nodeID == sub.id })
        let fileFill = try #require(fileSegment.fillRGB)
        let nestedFill = try #require(nestedSegment.fillRGB)
        let dirFill = try #require(dirSegment.fillRGB)
        // Files are gray (r == g == b); folders keep a saturated branch hue.
        #expect(fileFill.x == fileFill.y && fileFill.y == fileFill.z)
        #expect(nestedFill.x == nestedFill.y && nestedFill.y == nestedFill.z)
        #expect(!(dirFill.x == dirFill.y && dirFill.y == dirFill.z))
        #expect(segments.first { $0.nodeID == file.id }?.colorToken.role == .file)
        #expect(segments.first { $0.nodeID == sub.id }?.colorToken.role == .normal)
    }

    @Test func packagesAreFilesToTheSunburst() throws {
        // Packages (.app, .imovielibrary, …) are directories the scan never
        // descends into — the sunburst treats them as files: gray in branch
        // mode, not a drill target.
        let package = FileNodeRecord(
            id: "/root/iMovie Library.imovielibrary",
            url: URL(filePath: "/root/iMovie Library.imovielibrary", directoryHint: .isDirectory),
            name: "iMovie Library.imovielibrary",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 500,
            unduplicatedAllocatedSize: nil,
            logicalSize: 500,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: nil,
            linkCount: 1,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let nested = makeTestFileNode(id: "/root/sub/f", name: "f", size: 100)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [package, sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [package, sub],
            "/root/sub": [nested],
        ])

        #expect(!package.isSunburstFolder(in: store))
        #expect(sub.isSunburstFolder(in: store))

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 2,
            style: SunburstColorStyle(mode: .branch)
        )
        let packageSegment = try #require(segments.first { $0.nodeID == package.id })
        let packageFill = try #require(packageSegment.fillRGB)
        #expect(packageSegment.colorToken.role == .file)
        #expect(packageFill.x == packageFill.y && packageFill.y == packageFill.z)
    }

    @Test func expandedPackagesAreFoldersToTheSunburst() throws {
        // Once "Show Package Contents" splices a package's children into the
        // store it drills and colors like any other folder.
        let inner = makeTestFileNode(id: "/root/App.app/binary", name: "binary", size: 500)
        let package = FileNodeRecord(
            id: "/root/App.app",
            url: URL(filePath: "/root/App.app", directoryHint: .isDirectory),
            name: "App.app",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 500,
            unduplicatedAllocatedSize: nil,
            logicalSize: 500,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: nil,
            linkCount: 1,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [package])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [package],
            "/root/App.app": [inner],
        ])

        #expect(package.isSunburstFolder(in: store))

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 2,
            style: SunburstColorStyle(mode: .branch)
        )
        let packageSegment = try #require(segments.first { $0.nodeID == package.id })
        let packageFill = try #require(packageSegment.fillRGB)
        #expect(packageSegment.colorToken.role == .normal)
        #expect(!(packageFill.x == packageFill.y && packageFill.y == packageFill.z))
        // The package's children render as an inner ring.
        #expect(segments.contains { $0.nodeID == inner.id })
    }

    @Test func colorblindPaletteRestrictsBranchHues() throws {
        let nested = makeTestFileNode(id: "/root/sub/b.mov", name: "b.mov", size: 20)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub],
            "/root/sub": [nested],
        ])

        let standard = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1,
            style: SunburstColorStyle(mode: .branch, palette: .standard)
        )
        let colorblind = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1,
            style: SunburstColorStyle(mode: .branch, palette: .colorblind)
        )

        let standardSegment = try #require(standard.first { $0.nodeID == sub.id })
        let colorblindSegment = try #require(colorblind.first { $0.nodeID == sub.id })
        let standardFill = try #require(standardSegment.fillRGB)
        let colorblindFill = try #require(colorblindSegment.fillRGB)
        // The toggle must change the sunburst's default (branch) colors.
        #expect(standardFill != colorblindFill)
        // Colorblind fills keep the exact hue of an Okabe-Ito palette entry —
        // variation moves brightness only, so the hue must match one entry.
        let components = SunburstColorResolver.components(
            for: colorblindSegment.colorToken,
            palette: VizPalette.colorblind.sunburst
        )
        let paletteHues = VizPalette.colorblind.kindPalette.map { rgb -> Double in
            let r = Double(rgb.x), g = Double(rgb.y), b = Double(rgb.z)
            let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
            let delta = maxC - minC
            guard delta > 0 else { return 0 }
            var hue: Double
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            return hue < 0 ? hue + 1 : hue
        }
        #expect(paletteHues.contains { abs($0 - components.hue) < 0.001 })
    }

    @Test func kindModeResolvesCatalogFillsAtLayoutTime() throws {
        let movie = makeTestFileNode(id: "/root/a.mov", name: "a.mov", size: 600)
        let photo = makeTestFileNode(id: "/root/b.jpg", name: "b.jpg", size: 300)
        let nested = makeTestFileNode(id: "/root/sub/c.mov", name: "c.mov", size: 100)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [movie, photo, sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [movie, photo, sub],
            "/root/sub": [nested],
        ])
        let catalog = FileKindCatalog.build(from: store, mode: .types)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 2,
            style: SunburstColorStyle(mode: .kind, catalog: catalog)
        )

        let movieSegment = try #require(segments.first { $0.nodeID == movie.id })
        let dirSegment = try #require(segments.first { $0.nodeID == sub.id })
        #expect(movieSegment.fillRGB == catalog.rgb(for: movie))
        #expect(dirSegment.fillRGB == FileKindCatalog.directoryRGB)
    }

    @Test func kindHighlightDimsNonMatchingSegments() throws {
        let movie = makeTestFileNode(id: "/root/a.mov", name: "a.mov", size: 600)
        let photo = makeTestFileNode(id: "/root/b.jpg", name: "b.jpg", size: 300)
        let store = makeGeometryStore(children: [movie, photo])
        let catalog = FileKindCatalog.build(from: store, mode: .types)

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1,
            style: SunburstColorStyle(mode: .kind, catalog: catalog, highlight: .kind("mov"))
        )

        let movieSegment = try #require(segments.first { $0.nodeID == movie.id })
        let photoSegment = try #require(segments.first { $0.nodeID == photo.id })
        #expect(movieSegment.fillRGB == catalog.rgb(for: movie))
        #expect(photoSegment.fillRGB == TreemapScene.dimmedRGB(catalog.rgb(for: photo)))
    }

    @Test func ageModeUsesRampAgainstReferenceDate() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let fresh = makeTestFileNode(
            id: "/root/new.txt", name: "new.txt", size: 100,
            lastModified: reference.addingTimeInterval(-3_600)
        )
        let stale = makeTestFileNode(
            id: "/root/old.txt", name: "old.txt", size: 50,
            lastModified: reference.addingTimeInterval(-86_400 * 400)
        )
        let store = makeGeometryStore(children: [fresh, stale])

        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1,
            style: SunburstColorStyle(mode: .age(referenceDate: reference))
        )

        let freshSegment = try #require(segments.first { $0.nodeID == fresh.id })
        let staleSegment = try #require(segments.first { $0.nodeID == stale.id })
        #expect(freshSegment.fillRGB == VizPalette.standard.ageRGB(.day))
        #expect(staleSegment.fillRGB == VizPalette.standard.ageRGB(.older))
    }

    // MARK: - Cloud-only weighting & dataless marking (Neodisk-specific)

    @Test func cloudOnlyToggleGrowsDatalessArcWeightAndMarksIt() throws {
        let local = makeTestFileNode(id: "/root/local", name: "local", size: 100)
        let cloud = makeDatalessFileNode(id: "/root/cloud", name: "cloud", cloudBytes: 100)
        let store = makeGeometryStore(children: [local, cloud])

        let off = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, includeCloudOnly: false
        )
        let on = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, includeCloudOnly: true
        )

        let cloudOff = try #require(off.first { $0.nodeID == cloud.id })
        let cloudOn = try #require(on.first { $0.nodeID == cloud.id })
        let localOff = try #require(off.first { $0.nodeID == local.id })
        let localOn = try #require(on.first { $0.nodeID == local.id })

        func span(_ segment: SunburstSegment) -> Double { segment.endAngle - segment.startAngle }

        // Off counts on-disk bytes only, so the dataless file is a sliver and
        // the local file owns nearly the whole circle. On adds the cloud
        // bytes, so the equal-logical-size arcs split the circle evenly.
        #expect(span(cloudOn) > span(cloudOff))
        #expect(span(localOn) < span(localOff))
        #expect(abs(span(cloudOn) - span(localOn)) < 0.0001)
        #expect(abs(span(cloudOn) - .pi) < 0.0001)

        // The dataless bit rides the segment in both modes (it drives the
        // hatched fill); the local file never carries it.
        #expect(cloudOn.isDataless)
        #expect(cloudOff.isDataless)
        #expect(!localOn.isDataless)
        #expect(!localOff.isDataless)
    }

    @Test func entirelyCloudOnlyDirectoryIsMarkedAndDrillsOnlyWithToggle() throws {
        let cloudFile = makeDatalessFileNode(id: "/root/cloud/movie", name: "movie", cloudBytes: 200)
        let cloudDir = makeTestDirectoryNode(id: "/root/cloud", name: "cloud", children: [cloudFile])
        let local = makeTestFileNode(id: "/root/local", name: "local", size: 100)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [cloudDir, local])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [cloudDir, local],
            "/root/cloud": [cloudFile],
        ])

        // The directory holds no local bytes, only cloud-only descendants.
        #expect(cloudDir.allocatedSize == 0)
        #expect(cloudDir.cloudOnlyLogicalSize == 200)

        let off = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3, includeCloudOnly: false
        )
        let on = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3, includeCloudOnly: true
        )

        // A directory whose bytes all live in the cloud gets the hatch
        // marker, and with the toggle on it has the weight to drill so its
        // cloud child renders in the inner ring.
        let dirOn = try #require(on.first { $0.nodeID == cloudDir.id })
        #expect(dirOn.isDataless)
        #expect(on.contains { $0.nodeID == cloudFile.id })

        // With the toggle off the directory carries no on-disk weight, so
        // nothing recurses into it.
        #expect(!off.contains { $0.nodeID == cloudFile.id })
    }

    // MARK: - Angular seam

    @Test func drawnArcsInsetHalfTheSeamPerEdge() {
        let (start, end) = SunburstArcGeometry.seamInsetAngles(
            startRadians: 1,
            endRadians: 2,
            innerRadius: 0.4,
            outerRadius: 0.6
        )

        let expectedInset = (Double(SunburstLayout.angularSeam) / 2) / 0.5
        #expect(abs(start - (1 + expectedInset)) < 0.0001)
        #expect(abs(end - (2 - expectedInset)) < 0.0001)
    }

    @Test func fullCircleArcsStaySealed() {
        let (start, end) = SunburstArcGeometry.seamInsetAngles(
            startRadians: 0,
            endRadians: .pi * 2,
            innerRadius: 0.4,
            outerRadius: 0.6
        )

        #expect(start == 0)
        #expect(end == .pi * 2)
    }

    @Test func tinySliversCapTheSeamInset() {
        let span = 0.002
        let (start, end) = SunburstArcGeometry.seamInsetAngles(
            startRadians: 1,
            endRadians: 1 + span,
            innerRadius: 0.4,
            outerRadius: 0.6
        )

        // The seam yields before the item does: most of the arc survives.
        #expect(end > start)
        #expect((end - start) >= span * 0.6)
    }
}

// MARK: - Helpers

private func makeGeometryStore(children: [FileNodeRecord]) -> FileTreeStore {
    let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
    return FileTreeStore(root: root, childrenByID: ["/root": children])
}

/// A dataless (cloud-only) file: no on-disk bytes, `cloudBytes` of logical
/// content that lives only in the cloud. Local to this suite so the shared
/// TestFixtures stay untouched.
private func makeDatalessFileNode(id: String, name: String, cloudBytes: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: 0,
        unduplicatedAllocatedSize: nil,
        logicalSize: cloudBytes,
        descendantFileCount: 1,
        lastModified: nil,
        fileIdentity: nil,
        linkCount: 1,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false,
        isDataless: true
    )
}

private func pointInside(segment: SunburstSegment, in size: CGSize) -> CGPoint {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let maxRadius = min(size.width, size.height) / 2
    let radius = maxRadius * ((segment.innerRadius + segment.outerRadius) / 2)
    let angle = ((segment.startAngle + segment.endAngle) / 2) - (.pi / 2)

    return CGPoint(
        x: center.x + (cos(angle) * radius),
        y: center.y + (sin(angle) * radius)
    )
}

private func pointInRing(radius normalizedRadius: CGFloat, in size: CGSize) -> CGPoint {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let maxRadius = min(size.width, size.height) / 2
    return CGPoint(x: center.x, y: center.y - (normalizedRadius * maxRadius))
}

private func makeSegment(
    id: String,
    startAngle: Double = 0,
    endAngle: Double = .pi * 2,
    innerRadius: Double,
    outerRadius: Double,
    depth: Int
) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: startAngle,
        endAngle: endAngle,
        innerRadius: innerRadius,
        outerRadius: outerRadius,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false
    )
}
