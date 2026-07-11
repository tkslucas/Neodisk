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
            let hiddenSpaceBytes = gatedHiddenSpaceBytes
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
                        freeSpaceBytes: freeSpaceBytes,
                        hiddenSpaceBytes: hiddenSpaceBytes
                    ),
                    style: style,
                    freeSpaceBytes: freeSpaceBytes,
                    hiddenSpaceBytes: hiddenSpaceBytes,
                    centerSizeText: NeodiskFormatters.size(displayedFolder.allocatedSize),
                    onHoverSegment: { handleHover($0) },
                    onClickSegment: { handleClick($0) },
                    onPinchDrillSegment: { handlePinchDrill($0) },
                    onNavigateToParent: { model.zoomOut() },
                    onKeyDown: { handleKey($0) },
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
                resetPreviewFolder()
            }
            // Switching back to the treemap must not leave the status bar
            // holding the last-hovered sunburst item.
            .onDisappear {
                clearHover()
                resetPreviewFolder()
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
    /// drills into a subfolder. Unlike the treemap the sunburst shows it
    /// unconditionally for volume scans — no Settings toggle here.
    private var gatedFreeSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.freeSpaceBytes : nil
    }

    /// Hidden space follows the exact same volume/zoom gates as free space.
    private var gatedHiddenSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.hiddenSpaceBytes : nil
    }

    private func selectedAncestorIDs(in store: FileTreeStore) -> Set<String> {
        guard let selectedNodeID = model.selectedNodeID,
              store.node(id: selectedNodeID) != nil else { return [] }
        return Set(store.path(to: selectedNodeID).map(\.id))
    }

    /// One string capturing every GEOMETRY input, so `.task(id:)` reloads on
    /// any change: snapshot, root, depth, free space, hidden space. Colors
    /// (tab mode, highlight, palette, catalog) are deliberately absent —
    /// they restyle the rendered layout in place (see
    /// SunburstChartModel.applyStyle).
    private static func layoutID(
        snapshotID: UUID,
        rootID: String,
        freeSpaceBytes: Int64?,
        hiddenSpaceBytes: Int64?
    ) -> String {
        [
            snapshotID.uuidString,
            rootID,
            "\(depthLimit)",
            "\(freeSpaceBytes ?? 0)",
            "\(hiddenSpaceBytes ?? 0)"
        ].joined(separator: "|")
    }

    // MARK: - Interaction

    private func handleHover(_ segment: SunburstSegment?) {
        guard let segment else {
            clearHover()
            setPreviewFolder(nil)
            return
        }

        if segment.isFreeSpace || segment.isHiddenSpace {
            model.hoveredNodeID = nil
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = segment.isFreeSpace
            model.hoveredCellIsHiddenSpace = segment.isHiddenSpace
            setPreviewFolder(nil)
            return
        }

        if segment.isAggregate {
            model.hoveredNodeID = segment.parentFolderID
            model.hoveredAggregate = TreemapCell.AggregateInfo(
                itemCount: segment.itemCount,
                totalSize: segment.totalSize
            )
            model.hoveredCellIsFreeSpace = false
            model.hoveredCellIsHiddenSpace = false
            // Preview the containing folder — its list holds the Smaller
            // Items row this segment pools, which highlights through the
            // hover state above.
            setPreviewFolder(segment.parentFolderID)
            return
        }

        model.hoveredNodeID = segment.nodeID
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
        model.hoveredCellIsHiddenSpace = false
        // Hovering a directory previews its contents in the legend; files
        // (and childless folders, which have nothing to list) preview their
        // parent folder instead, so the legend shows the hovered item
        // highlighted among its siblings rather than snapping to the root.
        if let nodeID = segment.nodeID,
           let store = model.store,
           let node = store.node(id: nodeID) {
            if node.isSunburstFolder(in: store), !store.children(of: nodeID).isEmpty {
                setPreviewFolder(nodeID)
            } else {
                setPreviewFolder(store.parent(of: nodeID)?.id)
            }
        } else {
            setPreviewFolder(nil)
        }
    }

    /// Every preview change funnels through here so the legend's identity
    /// swap happens inside an animated transaction and cross-fades (see the
    /// `.transition(.opacity)` in SunburstLegendList). No debounce needed:
    /// hit-testing treats the ring gaps as glued to their arcs, so sliding
    /// folder→subfolder never drops the hover in between.
    private func setPreviewFolder(_ id: String?) {
        guard previewFolderID != id else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            previewFolderID = id
        }
    }

    /// Immediate, unanimated preview teardown for lifecycle changes (new
    /// root, view disappearing) where a fade would be stale.
    private func resetPreviewFolder() {
        previewFolderID = nil
    }

    private func clearHover() {
        model.hoveredNodeID = nil
        model.hoveredAggregate = nil
        model.hoveredCellIsFreeSpace = false
        model.hoveredCellIsHiddenSpace = false
    }

    /// Sunburst drills are pure navigation (DaisyDisk-style): a successful
    /// drill clears the selection so the breadcrumb tracks the drill root —
    /// keeping a stale selection (drillIn preserves one inside the new root,
    /// which suits the treemap's outline) reads as "that file is still
    /// selected" here. Refusals degrade to selecting the node.
    private func drillOrSelect(_ nodeID: String) {
        if model.drillIn(to: nodeID) {
            model.select(nil)
        } else {
            model.select(nodeID)
        }
    }

    private func handleClick(_ segment: SunburstSegment?) {
        guard let segment else {
            model.select(nil)
            return
        }

        if segment.isFreeSpace || segment.isHiddenSpace {
            model.select(nil)
            return
        }

        if segment.isAggregate {
            // Drilling into the containing folder gives the pooled items
            // more angle to spread out; when it is already the root (or
            // refuses), fall back to selecting the folder.
            guard let folderID = segment.parentFolderID else { return }
            drillOrSelect(folderID)
            return
        }

        guard let nodeID = segment.nodeID else { return }
        if let store = model.store, store.node(id: nodeID)?.isSunburstFolder(in: store) == true {
            // A single click on a folder segment drills in. drillIn guards
            // summarized/childless folders; refusals degrade to a plain
            // select.
            drillOrSelect(nodeID)
        } else {
            // A single click on a file (or a still-opaque package) selects
            // it and opens Quick Look (selection changes then live-update
            // the open panel).
            model.select(nodeID)
            if let node = model.store?.node(id: nodeID) {
                QuickLookPresenter.shared.openPreview(for: node)
            }
        }
    }

    /// Pinch-spread over a segment is pure navigation: drill into the
    /// folder (the aggregate's containing folder for pooled segments) and
    /// clear the selection like every sunburst drill. Unlike a click there
    /// is no select fallback — a refused or file-segment pinch does nothing,
    /// so an accidental pinch never moves the selection or opens Quick Look.
    private func handlePinchDrill(_ segment: SunburstSegment) {
        guard !segment.isFreeSpace, !segment.isHiddenSpace else { return }

        let targetID = segment.isAggregate ? segment.parentFolderID : segment.nodeID
        guard let targetID, let store = model.store,
              store.node(id: targetID)?.isSunburstFolder(in: store) == true,
              model.drillIn(to: targetID) else { return }
        model.select(nil)
    }

    // MARK: - Keyboard

    /// Keyboard navigation with the treemap's contract: arrows move the
    /// selection (←/→ around the ring, ↑ toward the center, ↓ outward to
    /// the largest child), ⌘↓/⌘↑ drill in/out, Space Quick Looks the
    /// selection, Return reveals it in Finder. Keyboard drills reuse the
    /// treemap's selection-anchoring semantics (drillIntoSelection lands on
    /// the largest child so arrows keep working) — deliberately unlike
    /// pointer drills, which are pure navigation and clear the selection
    /// (see drillOrSelect).
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == " " {
            model.quickLookSelection()
            return true
        }
        guard let key = event.specialKey else { return false }
        let command = event.modifierFlags.contains(.command)
        switch key {
        case .upArrow:
            if command { beepUnless(model.drillOut()) } else { moveSelection(.parent) }
        case .downArrow:
            if command { beepUnless(model.drillIntoSelection()) } else { moveSelection(.largestChild) }
        case .leftArrow:
            moveSelection(.previousSibling)
        case .rightArrow:
            moveSelection(.nextSibling)
        case .carriageReturn, .enter, .newline:
            model.revealSelection()
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ direction: SunburstKeyboardNav.Direction) {
        guard let store = model.store, let rootID = model.effectiveRootID,
              let target = SunburstKeyboardNav.target(
                  from: model.selectedNodeID,
                  direction: direction,
                  rootID: rootID,
                  store: store,
                  isRendered: { chartModel.segment(forNodeID: $0) != nil }
              ) else {
            NSSound.beep()
            return
        }
        model.select(target)
    }

    private func beepUnless(_ handled: Bool) {
        if !handled { NSSound.beep() }
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
            model.hoveredCellIsHiddenSpace = false
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
            model.hoveredCellIsHiddenSpace = false
            chartModel.setHoveredSegmentID(chartModel.segment(forSegmentID: row.id)?.id)
        case .freeSpace, .hiddenSpace:
            model.hoveredNodeID = nil
            model.hoveredAggregate = nil
            model.hoveredCellIsFreeSpace = row.target == .freeSpace
            model.hoveredCellIsHiddenSpace = row.target == .hiddenSpace
            chartModel.setHoveredSegmentID(chartModel.segment(forSegmentID: row.id)?.id)
        }
    }

    private func handleRowClick(_ row: SunburstLegendRow) {
        switch row.target {
        case .node(let nodeID, let isDirectory):
            if isDirectory {
                // Same as clicking the folder's segment: drill in, degrade
                // to select when drillIn refuses.
                drillOrSelect(nodeID)
            } else {
                model.select(nodeID)
                if let node = model.store?.node(id: nodeID) {
                    QuickLookPresenter.shared.openPreview(for: node)
                }
            }
        case .aggregate, .freeSpace, .hiddenSpace:
            // The aggregate's folder is already displayed and the synthetic
            // free/hidden-space arcs are not navigable — these rows are
            // hover-highlight only.
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
    /// Copy Path, plus Expand Contents / Show Package Contents for
    /// summarized folders and opaque packages.
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

        if let expansion = model.contentsExpansion(for: node) {
            menu.addItem(.separator())
            let item = SunburstMenuItem(title: NSLocalizedString(expansion.menuTitleKey, comment: "Sunburst context menu")) { model.expandNodeContents(node) }
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
