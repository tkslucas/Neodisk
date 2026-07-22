//
//  SunburstLegendTests.swift
//  Neodisk
//
//  The sunburst legend list derives its rows from the chart's rendered
//  segments — these tests pin the agreement: sort order, aggregate pooling,
//  free-space row gating, fill colors, and the hover→row mapping.
//

import SunburstCore
import Foundation
import SwiftUI
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct SunburstLegendTests {
    // MARK: - Sorting

    @Test func rowsSortChildrenBySizeDescending() {
        let children = [
            makeTestFileNode(id: "/root/small", name: "small", size: 1),
            makeTestFileNode(id: "/root/big", name: "big", size: 100),
            makeTestFileNode(id: "/root/mid", name: "mid", size: 10),
        ]
        let store = makeLegendStore(children: children)
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)

        let rows = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root",
            in: store, segments: segments, style: SunburstColorStyle()
        )

        #expect(rows.map(\.id) == ["/root/big", "/root/mid", "/root/small"])
        #expect(rows.map(\.size) == [100, 10, 1])
        #expect(rows.allSatisfy { !$0.isDimmed })
    }

    // MARK: - Aggregate pooling agreement

    @Test func pooledChildrenCollapseIntoOneAggregateRowMatchingTheChart() throws {
        let children = [
            makeTestFileNode(id: "/root/large", name: "large", size: 100),
            makeTestFileNode(id: "/root/tiny-1", name: "tiny-1", size: 1),
            makeTestFileNode(id: "/root/tiny-2", name: "tiny-2", size: 1),
            makeTestFileNode(id: "/root/tiny-3", name: "tiny-3", size: 1),
        ]
        let store = makeLegendStore(children: children)
        // A huge minimum angle forces the tiny files into the aggregate.
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, minimumAngle: .pi / 2
        )
        let aggregateSegment = try #require(segments.first { $0.isAggregate })

        let rows = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root",
            in: store, segments: segments, style: SunburstColorStyle()
        )

        // One individual row plus exactly one pooled row — never rows for
        // the pooled children themselves.
        #expect(rows.count == 2)
        #expect(rows[0].id == "/root/large")
        let aggregateRow = try #require(rows.last)
        #expect(aggregateRow.target == .aggregate)
        #expect(aggregateRow.id == aggregateSegment.id)
        #expect(aggregateRow.size == aggregateSegment.totalSize)
        #expect(aggregateRow.itemCount == aggregateSegment.itemCount)
        #expect(aggregateRow.isDimmed)
        #expect(aggregateRow.dotColor == SunburstChartStyler.baseStyle(for: aggregateSegment).fillColor)
    }

    // MARK: - Free space row

    @Test func freeSpaceRowAppearsOnlyWhenChartShowsTheArc() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 300)]
        let store = makeLegendStore(children: children)
        let style = SunburstColorStyle()

        let withFree = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, freeSpaceBytes: 100
        )
        let withoutFree = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)

        let rowsWithFree = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root", in: store, segments: withFree, style: style
        )
        let rowsWithoutFree = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root", in: store, segments: withoutFree, style: style
        )

        let freeRow = try #require(rowsWithFree.last)
        #expect(freeRow.target == .freeSpace)
        #expect(freeRow.size == 100)
        #expect(freeRow.isDimmed)
        #expect(!rowsWithoutFree.contains { $0.target == .freeSpace })
    }

    @Test func freeSpaceRowIsOmittedWhenPreviewingASubfolder() throws {
        let nested = makeTestFileNode(id: "/root/sub/file", name: "file", size: 50)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub],
            "/root/sub": [nested],
        ])
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3, freeSpaceBytes: 100
        )
        #expect(segments.contains { $0.isFreeSpace })

        // The legend previews /root/sub: free space belongs to the root
        // ring, so its row must not appear.
        let rows = SunburstLegend.rows(
            forFolder: "/root/sub", chartRootID: "/root",
            in: store, segments: segments, style: SunburstColorStyle()
        )

        #expect(rows.map(\.id) == ["/root/sub/file"])
    }

    // MARK: - Hidden space row

    @Test func hiddenSpaceRowAppearsBeforeFreeSpaceOnlyWhenTheChartShowsTheArc() throws {
        let children = [makeTestFileNode(id: "/root/a", name: "a", size: 300)]
        let store = makeLegendStore(children: children)
        let style = SunburstColorStyle()

        let withHidden = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1,
            freeSpaceBytes: 100, hiddenSpaceBytes: 50
        )
        let withoutHidden = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, freeSpaceBytes: 100
        )

        let rowsWithHidden = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root", in: store, segments: withHidden, style: style
        )
        let rowsWithoutHidden = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root", in: store, segments: withoutHidden, style: style
        )

        // Chart order: children, then the hidden arc, then the trailing
        // free arc.
        #expect(rowsWithHidden.map(\.target) == [
            .node(id: "/root/a", isDirectory: false), .hiddenSpace, .freeSpace,
        ])
        let hiddenRow = try #require(rowsWithHidden.first { $0.target == .hiddenSpace })
        #expect(hiddenRow.size == 50)
        #expect(hiddenRow.isDimmed)
        #expect(!rowsWithoutHidden.contains { $0.target == .hiddenSpace })
    }

    @Test func hiddenSpaceRowIsOmittedWhenPreviewingASubfolder() throws {
        let nested = makeTestFileNode(id: "/root/sub/file", name: "file", size: 50)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub],
            "/root/sub": [nested],
        ])
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 3, hiddenSpaceBytes: 100
        )
        #expect(segments.contains { $0.isHiddenSpace })

        let rows = SunburstLegend.rows(
            forFolder: "/root/sub", chartRootID: "/root",
            in: store, segments: segments, style: SunburstColorStyle()
        )

        #expect(rows.map(\.id) == ["/root/sub/file"])
    }

    // MARK: - Fill agreement with the chart

    @Test func rowDotsUseTheRenderedSegmentFills() throws {
        let children = [
            makeTestFileNode(id: "/root/a.mov", name: "a.mov", size: 600),
            makeTestFileNode(id: "/root/b.jpg", name: "b.jpg", size: 300),
        ]
        let store = makeLegendStore(children: children)
        let catalog = FileKindCatalog.build(from: store, mode: .types)
        let style = SunburstColorStyle(mode: .kind, catalog: catalog)
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, style: style
        )

        let rows = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root",
            in: store, segments: segments, style: style
        )

        for row in rows {
            let segment = try #require(segments.first { $0.nodeID == row.id })
            #expect(row.dotColor == SunburstChartStyler.baseStyle(for: segment).fillColor)
        }
    }

    @Test func fallbackFillsMatchWhatTheChartWouldRenderAtThatDepth() throws {
        // /root/sub's children at depth 1: a depthLimit-2 layout renders
        // them; a depthLimit-1 layout does not (max-depth preview folder).
        // The legend's fallback colors must equal the rendered ones — for
        // both branch mode and layout-resolved kind mode.
        let nestedChildren = [
            makeTestFileNode(id: "/root/sub/one.mov", name: "one.mov", size: 30),
            makeTestFileNode(id: "/root/sub/two.jpg", name: "two.jpg", size: 20),
        ]
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: nestedChildren)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub],
            "/root/sub": nestedChildren,
        ])
        let catalog = FileKindCatalog.build(from: store, mode: .types)

        for style in [SunburstColorStyle(mode: .branch), SunburstColorStyle(mode: .kind, catalog: catalog)] {
            let shallow = SunburstLayout.segments(
                in: store, rootID: "/root", depthLimit: 1, style: style
            )
            let deep = SunburstLayout.segments(
                in: store, rootID: "/root", depthLimit: 2, style: style
            )
            #expect(!shallow.contains { $0.depth == 1 })

            let rows = SunburstLegend.rows(
                forFolder: "/root/sub", chartRootID: "/root",
                in: store, segments: shallow, style: style
            )

            #expect(rows.count == nestedChildren.count)
            for row in rows {
                let renderedSegment = try #require(deep.first { $0.nodeID == row.id })
                #expect(row.dotColor == SunburstChartStyler.baseStyle(for: renderedSegment).fillColor)
            }
        }
    }

    // MARK: - Header

    @Test func headerUsesThePreviewedFolderSegmentFill() throws {
        let nested = makeTestFileNode(id: "/root/sub/file", name: "file", size: 50)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [nested])
        let other = makeTestFileNode(id: "/root/other", name: "other", size: 50)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub, other])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub, other],
            "/root/sub": [nested],
        ])
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 2)
        let subSegment = try #require(segments.first { $0.nodeID == "/root/sub" })
        let subNode = try #require(store.node(id: "/root/sub"))

        let header = SunburstLegend.headerRow(
            forFolder: subNode, chartRootID: "/root",
            in: store, segments: segments, style: SunburstColorStyle()
        )

        #expect(header.label == "sub")
        #expect(header.size == subNode.allocatedSize)
        #expect(header.dotColor == SunburstChartStyler.baseStyle(for: subSegment).fillColor)
    }

    // MARK: - Hover → row mapping

    @Test func hoveredDeepNodeMapsToItsTopLevelAncestorRow() {
        let nested = makeTestFileNode(id: "/root/sub/deep/file", name: "file", size: 10)
        let deep = makeTestDirectoryNode(id: "/root/sub/deep", name: "deep", children: [nested])
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [deep])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub])
        let store = FileTreeStore(root: root, childrenByID: [
            "/root": [sub],
            "/root/sub": [deep],
            "/root/sub/deep": [nested],
        ])

        #expect(SunburstLegend.rowNodeID(
            forHovered: "/root/sub/deep/file", displayedFolderID: "/root", in: store
        ) == "/root/sub")
        #expect(SunburstLegend.rowNodeID(
            forHovered: "/root/sub", displayedFolderID: "/root", in: store
        ) == "/root/sub")
        #expect(SunburstLegend.rowNodeID(
            forHovered: "/root/sub/deep/file", displayedFolderID: "/root/sub", in: store
        ) == "/root/sub/deep")
        // The displayed folder itself and nodes outside it map to no row.
        #expect(SunburstLegend.rowNodeID(
            forHovered: "/root", displayedFolderID: "/root", in: store
        ) == nil)
        #expect(SunburstLegend.rowNodeID(
            forHovered: "/root/sub", displayedFolderID: "/root/sub/deep", in: store
        ) == nil)
    }

    // MARK: - Presentation cache

    @Test func presentationCacheReusesStructureUntilAKeyInputChanges() throws {
        let child = makeTestFileNode(id: "/root/file.mov", name: "file.mov", size: 10)
        let store = makeLegendStore(children: [child])
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let root = try #require(store.node(id: "/root"))
        let style = SunburstColorStyle()
        let presentation = SunburstLegendPresentation(
            header: SunburstLegend.headerRow(
                forFolder: root, chartRootID: "/root", in: store,
                segments: segments, style: style
            ),
            rows: SunburstLegend.rows(
                forFolder: "/root", chartRootID: "/root", in: store,
                segments: segments, style: style
            )
        )
        var cache = SunburstLegendPresentationCache()
        let key = SunburstLegendPresentationKey(
            renderedLayoutVersion: 1,
            displayedFolderID: "/root",
            chartRootID: "/root",
            style: style,
            includeCloudOnly: false,
            headerSizeOverride: nil
        )

        _ = cache.value(for: key) { presentation }
        _ = cache.value(for: key) {
            Issue.record("Identical presentation key rebuilt")
            return presentation
        }
        #expect(cache.buildCount == 1)

        let nextVersion = SunburstLegendPresentationKey(
            renderedLayoutVersion: 2,
            displayedFolderID: key.displayedFolderID,
            chartRootID: key.chartRootID,
            style: key.style,
            includeCloudOnly: key.includeCloudOnly,
            headerSizeOverride: key.headerSizeOverride
        )
        _ = cache.value(for: nextVersion) { presentation }
        #expect(cache.buildCount == 2)

        let cloudWeighted = SunburstLegendPresentationKey(
            renderedLayoutVersion: nextVersion.renderedLayoutVersion,
            displayedFolderID: nextVersion.displayedFolderID,
            chartRootID: nextVersion.chartRootID,
            style: nextVersion.style,
            includeCloudOnly: true,
            headerSizeOverride: nextVersion.headerSizeOverride
        )
        _ = cache.value(for: cloudWeighted) { presentation }
        #expect(cache.buildCount == 3)
    }

    @Test func legendHoverSwatchIgnoresHighlightDimming() throws {
        let child = makeTestFileNode(id: "/root/file.mov", name: "file.mov", size: 10)
        let store = makeLegendStore(children: [child])
        let catalog = FileKindCatalog.build(from: store, mode: .types)
        let style = SunburstColorStyle(
            mode: .kind,
            catalog: catalog,
            highlight: .nodes(["/different-node"])
        )
        let segments = SunburstLayout.segments(
            in: store, rootID: "/root", depthLimit: 1, style: style
        )
        let segment = try #require(segments.first { $0.nodeID == child.id })
        let rows = SunburstLegend.rows(
            forFolder: "/root", chartRootID: "/root",
            in: store, segments: segments, style: style
        )
        let row = try #require(rows.first { $0.id == child.id })
        let semantic = catalog.rgb(for: child)

        #expect(row.swatchRGB == semantic)
        #expect(segment.fillRGB == TreemapScene.dimmedRGB(semantic))
    }
}

// MARK: - Helpers

private func makeLegendStore(children: [FileNodeRecord]) -> FileTreeStore {
    let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
    return FileTreeStore(root: root, childrenByID: ["/root": children])
}
