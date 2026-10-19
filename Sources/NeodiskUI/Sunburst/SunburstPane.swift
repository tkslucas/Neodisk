// Model-facing entry point for the sunburst: derives chart inputs from the view model and maps chart events
// to the same model actions the treemap uses.

import SunburstCore
import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit
import NeodiskAppModel

struct SunburstPane: View {
    /// The 6-ring body plus 2 thin detail rings at the edge (see SunburstRingMetrics).
    static let depthLimit = 8

    let model: NeodiskViewModel

    /// Shared between the chart and the legend list so both derive from the
    /// same rendered layout (segment fills, aggregate pooling, free space).
    @StateObject private var chartModel = SunburstChartModel()
    /// Driven only by chart hover: list-row hover must never move the preview, or it flickers.
    @State private var previewFolderID: String?
    /// Kept apart from legend-row hover (which also highlights a segment) to refresh a stationary chart hover
    /// after a palette or style change.
    @State private var chartHoveredSegmentID: SunburstSegment.ID?

    /// User-resizable, clamped on read against the pane width so the chart
    /// keeps a usable diameter (see SunburstLegendMetrics).
    @AppStorage("sunburstLegendWidth")
    private var legendWidth = PaneLayout.sunburstLegendDefaultWidth()
    /// Pointer-drag deltas stay local; the final width persists on mouse-up.
    @State private var transientLegendWidth: Double?

    var body: some View {
        if let store = model.store,
           let snapshot = model.coordinator.snapshot,
           let rootID = model.effectiveRootID,
           let rootNode = store.node(id: rootID) {
            let style = colorStyle
            let freeSpaceBytes = gatedFreeSpaceBytes
            let hiddenSpaceBytes = gatedHiddenSpaceBytes
            let displayedFolder = displayedFolder(rootNode: rootNode, in: store)
            GeometryReader { proxy in
                let legend = SunburstLegendMetrics(
                    availableWidth: proxy.size.width,
                    storedWidth: transientLegendWidth ?? legendWidth,
                    textScale: model.textScale
                )
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
                            hiddenSpaceBytes: hiddenSpaceBytes,
                            expandedAggregateIDs: model.expandedAggregateIDs,
                            includeCloudOnly: model.showsCloudOnlyFiles
                        ),
                        style: style,
                        freeSpaceBytes: freeSpaceBytes,
                        hiddenSpaceBytes: hiddenSpaceBytes,
                        expandedAggregateIDs: model.expandedAggregateIDs,
                        includeCloudOnly: model.showsCloudOnlyFiles,
                        centerSizeText: NeodiskFormatters.size(
                            displayedFolder.displayWeight(includingCloudOnly: model.showsCloudOnlyFiles)
                        ),
                        onHoverSegment: { handleHover($0) },
                        onClickSegment: { handleClick($0) },
                        onPinchDrillSegment: { handlePinchDrill($0) },
                        onNavigateToParent: { model.zoomOut() },
                        onKeyDown: { handleKey($0) },
                        contextMenu: { contextMenu(for: $0) },
                        chartModel: chartModel
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Too narrow for both: the legend and its divider hide.
                    if let resolvedLegendWidth = legend.width {
                        PaneSplitter(
                            size: liveLegendWidth,
                            range: legend.range,
                            defaultSize: PaneLayout.sunburstLegendDefaultWidth(scale: model.textScale),
                            paneEdge: .trailing,
                            onCommit: {
                                legendWidth = $0
                                transientLegendWidth = nil
                            }
                        )
                        SunburstLegendList(
                            model: model,
                            chartModel: chartModel,
                            displayedFolder: displayedFolder,
                            chartRootID: rootID,
                            style: style,
                            onHoverRow: { handleRowHover($0) },
                            onClickRow: { handleRowClick($0) },
                            onPinchRow: { handleRowPinch($0, direction: $1) }
                        )
                        .frame(width: resolvedLegendWidth)
                    }
                }
                // A new root (drill, breadcrumb, rescan) invalidates the preview.
                .onChange(of: model.effectiveRootID) { _, _ in
                    resetPreviewFolder()
                }
                .onChange(of: style) { _, _ in
                    refreshChartHoverSwatch(in: store)
                }
                // Switching back to the treemap must not leave the status bar
                // holding the last-hovered sunburst item.
                .onDisappear {
                    clearHover()
                    resetPreviewFolder()
                    transientLegendWidth = nil
                }
            }
        } else {
            Color.clear
        }
    }

    private var liveLegendWidth: Binding<Double> {
        Binding(
            get: { transientLegendWidth ?? legendWidth },
            set: { transientLegendWidth = $0 }
        )
    }

    /// The folder the legend and center hole describe: the hover-preview
    /// folder while the chart hovers a directory, otherwise the chart root.
    private func displayedFolder(rootNode: FileNodeRecord, in store: FileTreeStore) -> FileNodeRecord {
        guard let previewFolderID,
              let previewFolder = store.node(id: previewFolderID) else { return rootNode }
        return previewFolder
    }

    // MARK: - Color style

    /// Age uses the treemap's reference date; legend-less states (Largest tab, hidden panel) get branch hues.
    private var colorStyle: SunburstColorStyle {
        var style = SunburstColorStyle(
            mode: .branch,
            catalog: model.kinds.catalog,
            highlight: model.vizHighlight,
            palette: model.vizPalette
        )
        switch model.vizColorMode {
        case .kind:
            style.mode = .kind
        case .age(let referenceDate):
            style.mode = .age(referenceDate: referenceDate)
        case .branch:
            break
        }
        return style
    }

    /// Free space belongs to the whole volume, so it hides once drilled into a subfolder.
    private var gatedFreeSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.freeSpace.freeSpaceBytes : nil
    }

    /// Hidden space follows the exact same volume/zoom gates as free space.
    private var gatedHiddenSpaceBytes: Int64? {
        model.zoomRootID == nil ? model.freeSpace.hiddenSpaceBytes : nil
    }

    private func selectedAncestorIDs(in store: FileTreeStore) -> Set<String> {
        guard let selectedNodeID = model.selectedNodeID,
              store.node(id: selectedNodeID) != nil else { return [] }
        return Set(store.path(to: selectedNodeID).map(\.id))
    }

    /// Every geometry input, so `.task(id:)` reloads on any change. Colors are deliberately absent: they
    /// restyle the layout in place (SunburstChartModel.applyStyle).
    private static func layoutID(
        snapshotID: UUID,
        rootID: String,
        freeSpaceBytes: Int64?,
        hiddenSpaceBytes: Int64?,
        expandedAggregateIDs: Set<String>,
        includeCloudOnly: Bool
    ) -> String {
        [
            snapshotID.uuidString,
            rootID,
            "\(depthLimit)",
            "\(freeSpaceBytes ?? 0)",
            "\(hiddenSpaceBytes ?? 0)",
            expandedAggregateIDs.sorted().joined(separator: "+"),
            includeCloudOnly ? "cloud" : "local"
        ].joined(separator: "|")
    }

    // MARK: - Interaction

    private func handleHover(_ segment: SunburstSegment?) {
        chartHoveredSegmentID = segment?.id
        guard let segment else {
            clearHover()
            setPreviewFolder(nil)
            return
        }

        if segment.isFreeSpace || segment.isHiddenSpace {
            model.setVisualizationHover(
                segment.isFreeSpace
                    ? .freeSpace(swatchRGB: SyntheticSpaceColors.freeSpaceRGB)
                    : .hiddenSpace(swatchRGB: SyntheticSpaceColors.hiddenSpaceRGB)
            )
            setPreviewFolder(nil)
            return
        }

        if segment.isAggregate {
            guard let folderID = segment.parentFolderID else {
                clearHover()
                setPreviewFolder(nil)
                return
            }
            model.setVisualizationHover(.aggregate(
                folderID: folderID,
                itemCount: segment.itemCount,
                totalSize: segment.totalSize,
                swatchRGB: FileKindCatalog.otherRGB
            ))
            // The containing folder's list holds the Smaller Items row this segment pools.
            setPreviewFolder(segment.parentFolderID)
            return
        }

        if let nodeID = segment.nodeID,
           let node = model.store?.node(id: nodeID) {
            model.setVisualizationHover(.node(
                id: nodeID,
                swatchRGB: SunburstLayout.semanticFillRGB(
                    for: node, token: segment.colorToken, style: colorStyle
                )
            ))
        } else {
            clearHover()
        }
        // Files and childless folders preview their parent, so the hovered item shows highlighted among its
        // siblings instead of the legend snapping to the root.
        if let nodeID = segment.nodeID,
           let store = model.store,
           let node = store.node(id: nodeID) {
            if node.isSunburstFolder(in: store), store.containsChildren(id: nodeID) {
                setPreviewFolder(nodeID)
            } else {
                setPreviewFolder(store.parent(of: nodeID)?.id)
            }
        } else {
            setPreviewFolder(nil)
        }
    }

    /// The chart publishes only segment-identity edges, but a style change can recolor a stationary segment.
    private func refreshChartHoverSwatch(in store: FileTreeStore) {
        guard let chartHoveredSegmentID,
              let segment = chartModel.segment(forSegmentID: chartHoveredSegmentID) else { return }
        if segment.isFreeSpace {
            model.setVisualizationHover(.freeSpace(swatchRGB: SyntheticSpaceColors.freeSpaceRGB))
        } else if segment.isHiddenSpace {
            model.setVisualizationHover(.hiddenSpace(swatchRGB: SyntheticSpaceColors.hiddenSpaceRGB))
        } else if segment.isAggregate, let folderID = segment.parentFolderID {
            model.setVisualizationHover(.aggregate(
                folderID: folderID,
                itemCount: segment.itemCount,
                totalSize: segment.totalSize,
                swatchRGB: FileKindCatalog.otherRGB
            ))
        } else if let nodeID = segment.nodeID, let node = store.node(id: nodeID) {
            model.setVisualizationHover(.node(
                id: nodeID,
                swatchRGB: SunburstLayout.semanticFillRGB(
                    for: node, token: segment.colorToken, style: colorStyle
                )
            ))
        }
    }

    /// Animated so the legend cross-fades. No debounce needed: hit-testing glues ring gaps to their arcs.
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
        model.setVisualizationHover(nil)
    }

    /// Pointer drills clear the selection so a stale one doesn't read as still selected; refusals select.
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
            // Drilling into the containing folder gives pooled items more angle; else select the folder.
            guard let folderID = segment.parentFolderID else { return }
            drillOrSelect(folderID)
            return
        }

        guard let nodeID = segment.nodeID else { return }
        if let store = model.store, store.node(id: nodeID)?.isSunburstFolder(in: store) == true {
            // drillIn guards summarized and childless folders.
            drillOrSelect(nodeID)
        } else {
            // Later selection changes live-update the open Quick Look panel.
            model.select(nodeID)
            if let node = model.store?.node(id: nodeID) {
                QuickLookPresenter.shared.openPreview(for: node)
            }
        }
    }

    /// Unlike a click there is no select fallback, so an accidental pinch never moves the selection or
    /// opens Quick Look.
    private func handlePinchDrill(_ segment: SunburstSegment) {
        guard !segment.isFreeSpace, !segment.isHiddenSpace else { return }

        let targetID = segment.isAggregate ? segment.parentFolderID : segment.nodeID
        guard let targetID, let store = model.store,
              store.node(id: targetID)?.isSunburstFolder(in: store) == true,
              model.drillIn(to: targetID) else { return }
        model.select(nil)
    }

    // MARK: - Keyboard

    /// Keyboard drills keep the treemap's selection anchoring (drill lands on the largest child), unlike
    /// pointer drills, which clear the selection.
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
            model.setVisualizationHover(.node(id: nodeID, swatchRGB: row.swatchRGB))
            chartModel.setHoveredSegmentID(chartModel.segment(forNodeID: nodeID)?.id)
        case .aggregate:
            // Mirror hovering the aggregate segment itself: the status bar
            // reads "N smaller items in <displayed folder>".
            guard let displayedFolderID else { return }
            model.setVisualizationHover(.aggregate(
                folderID: displayedFolderID,
                itemCount: row.itemCount,
                totalSize: row.size,
                swatchRGB: row.swatchRGB
            ))
            chartModel.setHoveredSegmentID(chartModel.segment(forSegmentID: row.id)?.id)
        case .freeSpace, .hiddenSpace:
            model.setVisualizationHover(
                row.target == .freeSpace
                    ? .freeSpace(swatchRGB: row.swatchRGB)
                    : .hiddenSpace(swatchRGB: row.swatchRGB)
            )
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
        case .aggregate:
            // Lays out the displayed folder's small children individually, like the treemap's cell click.
            guard let displayedFolderID else { return }
            model.expandAggregate(inFolder: displayedFolderID)
        case .freeSpace, .hiddenSpace:
            // The synthetic free/hidden-space arcs are not navigable —
            // these rows are hover-highlight only.
            break
        }
    }

    /// Spread over a row drills in (no select fallback), a squeeze anywhere goes up one level.
    private func handleRowPinch(_ row: SunburstLegendRow?, direction: SunburstPinchDirection) {
        switch direction {
        case .drillIn:
            let targetID: String?
            switch row?.target {
            case .node(let nodeID, let isDirectory):
                targetID = isDirectory ? nodeID : nil
            case .aggregate:
                targetID = displayedFolderID
            case .freeSpace, .hiddenSpace, nil:
                targetID = nil
            }
            guard let targetID, model.drillIn(to: targetID) else { return }
            model.select(nil)
        case .drillOut:
            model.drillOut()
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

    private func contextMenu(for segment: SunburstSegment) -> NSMenu? {
        guard let nodeID = segment.nodeID,
              let node = model.store?.node(id: nodeID) else { return nil }
        return NSMenu.fileNodeActions(for: node, model: model)
    }
}
