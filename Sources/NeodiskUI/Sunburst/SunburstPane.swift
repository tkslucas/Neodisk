//
//  SunburstPane.swift
//  Neodisk
//
//  Model-facing entry point for the sunburst view: derives the chart's
//  inputs (root, color style, free space, layout identity) from the view
//  model and translates chart events into the same model actions the
//  treemap uses — hover to the status bar, single-click drill-in, center
//  click out, and the shared file-action context menu.
//

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit

struct SunburstPane: View {
    /// Rings drawn below the focused root (no settings knob in v1).
    static let depthLimit = 6

    let model: NeodiskViewModel

    /// Shared between the chart and the legend list so both derive from the
    /// same rendered layout (segment fills, aggregate pooling, free space).
    @StateObject private var chartModel = SunburstChartModel()
    /// The folder the legend previews while the chart hovers a directory
    /// segment; nil shows the chart root. Driven ONLY by chart hover — list
    /// row hover must never move the preview (no flicker).
    @State private var previewFolderID: String?

    var body: some View {
        if let store = model.store,
           let snapshot = model.coordinator.snapshot,
           let rootID = model.effectiveRootID,
           let rootNode = store.node(id: rootID) {
            let style = colorStyle
            let freeSpaceBytes = gatedFreeSpaceBytes
            let displayedFolder = displayedFolder(rootNode: rootNode, in: store)
            HStack(spacing: 0) {
                SunburstChartView(
                    rootNode: rootNode,
                    parentNode: store.parent(of: rootID),
                    treeStore: store,
                    selectedNodeID: model.selectedNodeID,
                    selectedAncestorIDs: selectedAncestorIDs(in: store),
                    depthLimit: Self.depthLimit,
                    layoutID: Self.layoutID(
                        snapshotID: snapshot.id,
                        rootID: rootID,
                        style: style,
                        freeSpaceBytes: freeSpaceBytes
                    ),
                    viewportResetID: "\(snapshot.id)|\(rootID)",
                    style: style,
                    freeSpaceBytes: freeSpaceBytes,
                    centerSizeText: NeodiskFormatters.size(displayedFolder.allocatedSize),
                    onHoverSegment: { handleHover($0) },
                    onClickSegment: { handleClick($0) },
                    onNavigateToParent: { model.zoomOut() },
                    contextMenu: { contextMenu(for: $0) },
                    chartModel: chartModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                SunburstLegendList(
                    model: model,
                    chartModel: chartModel,
                    displayedFolder: displayedFolder,
                    chartRootID: rootID,
                    style: style,
                    onHoverRow: { handleRowHover($0) },
                    onClickRow: { handleRowClick($0) }
                )
            }
            // A new root (drill, breadcrumb, rescan) invalidates the preview.
            .onChange(of: model.effectiveRootID) { _, _ in
                previewFolderID = nil
            }
            // Switching back to the treemap must not leave the status bar
            // holding the last-hovered sunburst item.
            .onDisappear {
                clearHover()
                previewFolderID = nil
            }
        } else {
            Color.clear
        }
    }

    /// The folder the legend and center hole describe: the hover-preview
    /// folder while the chart hovers a directory, otherwise the chart root.
    private func displayedFolder(rootNode: FileNodeRecord, in store: FileTreeStore) -> FileNodeRecord {
        guard let previewFolderID,
              let previewFolder = store.node(id: previewFolderID) else { return rootNode }
        return previewFolder
    }

    // MARK: - Color style

    /// The active tab's coloring, mirroring `treemapColorMode` semantics:
    /// Largest gets Radix branch hues, Age the ramp with the same reference
    /// date as the treemap, everything else kind colors — with the active
    /// tab's highlight dimming baked in. The statistics panel is the legend
    /// for the kind/age lenses, so hiding it reverts the sunburst to its
    /// default branch colors (and drops any highlight dim); reopening it
    /// brings the tab's colors back.
    private var colorStyle: SunburstColorStyle {
        var style = SunburstColorStyle(
            mode: .branch,
            catalog: model.kinds.catalog,
            highlight: model.showKindStats ? model.treemapHighlight : nil,
            palette: model.vizPalette
        )
        guard model.showKindStats, model.analysisTab != .largest else { return style }
        switch model.treemapColorMode {
        case .kind:
            style.mode = .kind
        case .age(let referenceDate):
            style.mode = .age(referenceDate: referenceDate)
        }
        return style
    }

    /// Free space belongs to the volume as a whole; hide it once the user
    /// drills into a subfolder (same gate as TreemapPane).
    private var gatedFreeSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.freeSpaceBytes : nil
    }

    private func selectedAncestorIDs(in store: FileTreeStore) -> Set<String> {
        guard let selectedNodeID = model.selectedNodeID,
              store.node(id: selectedNodeID) != nil else { return [] }
        return Set(store.path(to: selectedNodeID).map(\.id))
    }

    /// One string capturing every layout input, so `.task(id:)` reloads on
    /// any change: snapshot, root, color mode, highlight, palette, free space.
    private static func layoutID(
        snapshotID: UUID,
        rootID: String,
        style: SunburstColorStyle,
        freeSpaceBytes: Int64?
    ) -> String {
        let modeKey: String
        switch style.mode {
        case .branch:
            modeKey = "branch"
        case .kind:
            modeKey = "kind"
        case .age(let referenceDate):
            modeKey = "age:\(referenceDate.timeIntervalSinceReferenceDate)"
        }

        let highlightKey: String
        switch style.highlight {
        case nil:
            highlightKey = "none"
        case .kind(let kindID):
            highlightKey = "kind:\(kindID)"
        case .ageBucket(let bucket):
            highlightKey = "age:\(bucket.rawValue)"
        case .nodes(let ids):
            // Duplicate groups can hold thousands of ids; a stable FNV-1a
            // digest keeps the layout id cheap while still changing whenever
            // the set does.
            highlightKey = "nodes:\(ids.count):\(stableDigest(of: ids))"
        }

        let paletteKey = style.palette == .colorblind ? "cb" : "std"
        return [
            snapshotID.uuidString,
            rootID,
            "\(depthLimit)",
            modeKey,
            highlightKey,
            paletteKey,
            style.catalog.buildID.uuidString,
            "\(freeSpaceBytes ?? 0)"
        ].joined(separator: "|")
    }

    private static func stableDigest(of ids: Set<String>) -> UInt64 {
        // Order-independent: combine per-id FNV-1a hashes commutatively.
        var combined: UInt64 = 0
        for id in ids {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            combined &+= hash
        }
        return combined
    }

    // MARK: - Interaction

    private func handleHover(_ segment: SunburstSegment?) {
        guard let segment else {
            clearHover()
            previewFolderID = nil
            return
        }

        if segment.isFreeSpace {
            model.hoveredNodeID = nil
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = true
            previewFolderID = nil
            return
        }

        if segment.isAggregate {
            model.hoveredNodeID = segment.parentFolderID
            model.hoveredAggregate = TreemapCell.AggregateInfo(
                itemCount: segment.itemCount,
                totalSize: segment.totalSize
            )
            model.hoveredCellIsFreeSpace = false
            previewFolderID = nil
            return
        }

        model.hoveredNodeID = segment.nodeID
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
        // Hovering a directory previews its contents in the legend; files
        // (and childless folders, which have nothing to list) keep the list
        // on the current root and highlight their containing row instead.
        if let nodeID = segment.nodeID,
           let node = model.store?.node(id: nodeID),
           node.isDirectory,
           model.store?.children(of: nodeID).isEmpty == false {
            previewFolderID = nodeID
        } else {
            previewFolderID = nil
        }
    }

    private func clearHover() {
        model.hoveredNodeID = nil
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
    }

    private func handleClick(_ segment: SunburstSegment?) {
        guard let segment else {
            model.select(nil)
            return
        }

        if segment.isFreeSpace {
            model.select(nil)
            return
        }

        if segment.isAggregate {
            // Drilling into the containing folder gives the pooled items
            // more angle to spread out; when it is already the root (or
            // refuses), fall back to selecting the folder.
            guard let folderID = segment.parentFolderID else { return }
            if !model.drillIn(to: folderID) {
                model.select(folderID)
            }
            return
        }

        guard let nodeID = segment.nodeID else { return }
        if model.store?.node(id: nodeID)?.isDirectory == true {
            // A single click on a folder segment drills in. drillIn guards
            // summarized/childless folders and manages the selection;
            // refusals degrade to a plain select.
            if !model.drillIn(to: nodeID) {
                model.select(nodeID)
            }
        } else {
            // A single click on a file selects it and opens Quick Look
            // (selection changes then live-update the open panel).
            model.select(nodeID)
            if let node = model.store?.node(id: nodeID) {
                QuickLookPresenter.shared.openPreview(for: node)
            }
        }
    }

    // MARK: - Legend list interaction

    /// List row hover feeds the chart highlight and the status bar but must
    /// never move the legend preview (that is chart-hover-only).
    private func handleRowHover(_ row: SunburstLegendRow?) {
        guard let row else {
            clearHover()
            chartModel.setHoveredSegmentID(nil)
            return
        }

        switch row.target {
        case .node(let nodeID, _):
            model.hoveredNodeID = nodeID
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = false
            chartModel.setHoveredSegmentID(chartModel.segment(forNodeID: nodeID)?.id)
        case .aggregate:
            // Mirror hovering the aggregate segment itself: the status bar
            // reads "N smaller items in <displayed folder>".
            model.hoveredNodeID = displayedFolderID
            model.hoveredAggregate = TreemapCell.AggregateInfo(
                itemCount: row.itemCount,
                totalSize: row.size
            )
            model.hoveredCellIsFreeSpace = false
            chartModel.setHoveredSegmentID(chartModel.segment(forSegmentID: row.id)?.id)
        case .freeSpace:
            model.hoveredNodeID = nil
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = true
            chartModel.setHoveredSegmentID(chartModel.segment(forSegmentID: row.id)?.id)
        }
    }

    private func handleRowClick(_ row: SunburstLegendRow) {
        switch row.target {
        case .node(let nodeID, let isDirectory):
            if isDirectory {
                // Same as clicking the folder's segment: drill in, degrade
                // to select when drillIn refuses.
                if !model.drillIn(to: nodeID) {
                    model.select(nodeID)
                }
            } else {
                model.select(nodeID)
                if let node = model.store?.node(id: nodeID) {
                    QuickLookPresenter.shared.openPreview(for: node)
                }
            }
        case .aggregate, .freeSpace:
            // The aggregate's folder is already displayed and free space is
            // not navigable — these rows are hover-highlight only.
            break
        }
    }

    /// The folder the legend currently lists — the hover preview or the
    /// chart root (mirrors `displayedFolder(rootNode:in:)` for handlers).
    private var displayedFolderID: String? {
        if let previewFolderID, model.store?.node(id: previewFolderID) != nil {
            return previewFolderID
        }
        return model.effectiveRootID
    }

    /// Same actions as the treemap's context menu: Reveal in Finder / Open /
    /// Copy Path, plus Expand Contents for summarized folders.
    private func contextMenu(for segment: SunburstSegment) -> NSMenu? {
        guard let nodeID = segment.nodeID,
              let node = model.store?.node(id: nodeID),
              node.supportsFileActions else { return nil }

        let model = model
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "Sunburst context menu")) { model.reveal(node) })
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Open", comment: "Sunburst context menu")) { model.open(node) })
        menu.addItem(SunburstMenuItem(title: NSLocalizedString("Copy Path", comment: "Sunburst context menu")) { model.copyPath(node) })

        if node.isAutoSummarized {
            menu.addItem(.separator())
            let item = SunburstMenuItem(title: NSLocalizedString("Expand Contents", comment: "Sunburst context menu")) { model.expandSummarizedNode(node) }
            item.isEnabled = model.canRefreshSubtree
            menu.addItem(item)
        }
        return menu
    }
}

/// NSMenuItem that runs a closure; NSMenu's target/action plumbing needs an
/// object to point at, and the item itself is the natural owner.
private final class SunburstMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("SunburstMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}
