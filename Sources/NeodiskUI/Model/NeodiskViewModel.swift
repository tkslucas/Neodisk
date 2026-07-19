//
//  NeodiskViewModel.swift
//  Neodisk
//
//  Central UI state: scan lifecycle, selection, zoom, kind statistics, and
//  the rendered treemap.
//

import SunburstCore
import AppKit
import Combine
import Observation
import SwiftUI
import TreemapKit
import NeodiskKit

@MainActor
@Observable
final class NeodiskViewModel {
    let coordinator: ScanCoordinator

    var selectedNodeID: String? {
        didSet {
            guard selectedNodeID != oldValue else { return }
            // Any selection — from the treemap, outline, sidebar lists, or
            // search — keeps itself on screen: if it lands outside a
            // drilled-in map, widen the root out to reveal it. Done here, not
            // in select(), because the outline sets selectedNodeID directly.
            if let selectedNodeID { widenRootToShow(selectedNodeID) }
            // Live-update an open Quick Look panel as the selection moves
            // (arrow-keying through the outline). No-op when it's closed.
            QuickLookPresenter.shared.selectionDidChange(to: selectedNode)
        }
    }
    var hoveredNodeID: String?
    /// Set while the cursor is over a merged "smaller items" treemap cell;
    /// `hoveredNodeID` then points at the containing folder.
    var hoveredAggregate: TreemapCell.AggregateInfo?
    /// True while the cursor is over the synthetic free-space cell (whose
    /// node exists in no tree store).
    var hoveredCellIsFreeSpace = false
    /// True while the cursor is over the synthetic hidden-space cell (whose
    /// node exists in no tree store).
    var hoveredCellIsHiddenSpace = false
    /// Node the treemap is currently zoomed into; nil means the snapshot root.
    var zoomRootID: String?
    /// Folders whose "smaller items" cell the user clicked open — their
    /// children render individually even when tiny.
    var expandedAggregateIDs: Set<String> = []
    var showKindStats = true {
        didSet { syncDiffVisibility() }
    }
    /// Which statistics-panel tab is active. Also decides what treemap color
    /// means (Age colors by modification date; the others keep kind colors)
    /// and which drill-in highlight reaches the map — see treemapColorMode /
    /// treemapHighlight. Deliberately not reset per scan: the chosen lens
    /// carries across locations. Starts on Largest — the first tab, and the
    /// first question a disk tool gets asked.
    var analysisTab: AnalysisTab = .largest {
        didSet { syncDiffVisibility() }
    }
    /// Locations sidebar visibility; lives here so the View menu can toggle
    /// it. Always starts visible.
    var sidebarVisibility = NavigationSplitViewVisibility.all
    /// Which visualization the center pane shows (treemap or sunburst).
    /// Preference mirroring happens where the toolbar switcher binds.
    /// The diff stays armed across the switch: sunburst has no Δ column to
    /// render, but switching back to the treemap must not lose the mode.
    var vizViewMode: VizViewMode = .treemap
    /// Mirror of the persisted treemap style (cushion or flat), synced by
    /// bindPreferences — same pattern as vizViewMode.
    var treemapStyle: TreemapStyle = .cushion

    // MARK: Kind statistics

    /// Kind catalog, display mode, and drill-in file list; see
    /// KindStatsModel.
    let kinds: KindStatsModel

    // MARK: Largest files

    /// The whole scan's biggest files, flat and size-descending; see
    /// LargestFilesModel.
    let largest: LargestFilesModel

    // MARK: Age statistics

    /// Modification-age buckets and drill-in file list; see AgeStatsModel.
    let ages: AgeStatsModel

    // MARK: Duplicates

    /// On-demand duplicate-content scan and results; see DuplicatesModel.
    let duplicates: DuplicatesModel

    // MARK: Changes list

    /// Added/deleted/renamed/grown/shrunk entries against the previous
    /// scan, for the statistics panel's Changes tab; see ChangesModel.
    let changes: ChangesModel

    // MARK: Entire-scan search

    /// Outline "search entire scan" feature state; see SearchModel.
    let search: SearchModel

    var expandedNodeIDs: Set<String> = []
    var actionErrorMessage: String?
    /// True after the user stops a scan mid-flight while partial results are
    /// on screen: the scan strip stays visible offering Resume.
    var scanWasStopped = false
    /// Shows the first-launch welcome sheet (also reachable from Settings).
    var showWelcomeSheet = false

    // MARK: Scan warnings

    /// Floating-panel warning visibility, dismissals, and the Full Disk
    /// Access probe; see ScanWarningsModel.
    let warnings: ScanWarningsModel
    /// The sidebar's Folders section: seeded with the common folders on
    /// first launch, extended by Add Folder, every entry removable.
    var sidebarFolders: [ScanTarget] = []
    /// Mounted volumes shown in the sidebar's Volumes section.
    let volumeLocations = SystemIntegration.volumeTargets()
    /// Locally-synced cloud storage folders (iCloud Drive, File Provider
    /// roots), shown in the sidebar's own "Local Cloud Files" section.
    let cloudLocations = SystemIntegration.cloudTargets()
    /// Connected remote cloud-drive accounts and their connect/sign-out
    /// flows; see CloudAccountsModel.
    let cloudAccounts: CloudAccountsModel
    /// The fixed sidebar locations: volumes, local cloud folders, and remote
    /// cloud-drive accounts. Unlike the Folders section these can never be
    /// removed. Feeding cloud accounts through here joins them into sidebar
    /// selection (`allTargets`), dedup, and the snapshot-cache keep-list.
    var builtInLocations: [ScanTarget] { volumeLocations + cloudLocations + cloudAccounts.accounts }

    // MARK: Scan session

    /// startScan's branch choice, the auto-rescan policy and notice, the
    /// snapshot-cache index, and scan persistence; see ScanSessionModel.
    let session: ScanSessionModel
    /// "Changes since last scan" baseline; see DiffModel. Visibility is
    /// driven by the Changes tab (`wantsDiffVisible`), not a toolbar toggle.
    let diff: DiffModel

    /// The Changes tab owns the diff display: while it is the active tab of
    /// a visible statistics panel, the outline shows its Δ column (and the
    /// tab its list). Hiding the panel or switching tabs turns both off —
    /// the same contract the sunburst uses for tab-driven coloring.
    var wantsDiffVisible: Bool {
        showKindStats && analysisTab == .changes
    }

    private func syncDiffVisibility() {
        diff.setShowing(wantsDiffVisible)
    }
    // MARK: Free & hidden space

    /// Volume free space, hidden space, and cloud quota remainders; see
    /// FreeSpaceModel.
    let freeSpace: FreeSpaceModel

    /// Mirror of the persisted cloud-only toggle, synced by bindPreferences
    /// so observation fires when it flips (same pattern as free space).
    var showCloudOnlyFilesPreferred = true
    /// Whether the displayed snapshot contains any cloud-only (dataless)
    /// bytes — gates the toolbar toggle, which is otherwise a no-op.
    var snapshotHasCloudItems: Bool {
        guard let store = coordinator.snapshot?.treeStore else { return false }
        return (store.node(id: store.rootID)?.cloudOnlyLogicalSize ?? 0) > 0
    }
    /// The effective display flag both visualizations weight by:
    /// preference on, and the snapshot actually has cloud-only bytes.
    var showsCloudOnlyFiles: Bool {
        showCloudOnlyFilesPreferred && snapshotHasCloudItems
    }

    /// Settings backing scan options and the free-space cell; assigned once
    /// by the app at launch.
    var preferences: AppPreferences? {
        didSet { bindPreferences() }
    }

    /// One search index per displayed snapshot, shared by the outline
    /// search and the kind drill-in list.
    @ObservationIgnored private let searchIndexService = SearchIndexService()
    @ObservationIgnored private let sidebarFolderStore: SidebarFolderStore
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    @ObservationIgnored private var preferencesCancellable: AnyCancellable?

    init(
        coordinator: ScanCoordinator = ScanCoordinator(),
        snapshotCache: ScanSnapshotCache = ScanSnapshotCache(),
        sidebarFolderStore: SidebarFolderStore = SidebarFolderStore(),
        cloudScan: (any CloudScanIntegrating)? = nil
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.sidebarFolderStore = sidebarFolderStore
        self.warnings = ScanWarningsModel(coordinator: coordinator)
        self.freeSpace = FreeSpaceModel(coordinator: coordinator, cloudScan: cloudScan)
        // Seeds the connected cloud accounts before the keep-list below is
        // computed, so their persisted snapshots survive the launch prune
        // (builtInLocations folds cloudAccounts.accounts in).
        self.cloudAccounts = CloudAccountsModel(
            coordinator: coordinator,
            snapshotCache: snapshotCache,
            integration: cloudScan
        )
        self.search = SearchModel(coordinator: coordinator, indexService: searchIndexService)
        self.kinds = KindStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.largest = LargestFilesModel(coordinator: coordinator, indexService: searchIndexService)
        self.ages = AgeStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.duplicates = DuplicatesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.diff = DiffModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.changes = ChangesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.session = ScanSessionModel(
            coordinator: coordinator,
            snapshotCache: snapshotCache,
            kinds: kinds,
            diff: diff,
            changes: changes,
            duplicates: duplicates
        )
        sidebarFolders = sidebarFolderStore.load()
        diff.model = self
        changes.model = self
        cloudAccounts.model = self
        session.model = self

        // The coordinator is @Observable, so views track its properties
        // (phase, snapshot, …) directly; the model only needs the snapshot
        // change hook for its own bookkeeping.
        coordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshotDidChange(snapshot)
        }

        coordinator.onScanFinished = { [weak self] snapshot in
            self?.session.scanDidFinish(snapshot)
        }

        // Drop cache entries for locations no longer in the sidebar and
        // learn which targets can open instantly from cache. A NEODISK_AUTOSCAN
        // dev-hook target is kept too even when it is not a sidebar location,
        // so a bench relaunch (app-bench.sh --rescan) finds the baseline the
        // previous run persisted instead of having it pruned as an orphan.
        var keepTargetIDs = Set((builtInLocations + sidebarFolders).map(\.id))
        if let path = ProcessInfo.processInfo.environment["NEODISK_AUTOSCAN"],
           !path.contains("://") {
            keepTargetIDs.insert(
                ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)).id
            )
        }
        session.pruneAndIndexCache(keepingTargetIDs: keepTargetIDs)
    }

    /// Selecting a location: the scan session picks the restore / refresh /
    /// live-scan branch; see ScanSessionModel.startScan.
    func startScan(_ target: ScanTarget, forcesRescan: Bool = false) {
        session.startScan(target, forcesRescan: forcesRescan)
    }

    var store: FileTreeStore? {
        coordinator.snapshot?.treeStore
    }

    var effectiveRootID: String? {
        guard let store else { return nil }
        if let zoomRootID, store.node(id: zoomRootID) != nil {
            return zoomRootID
        }
        return store.root.id
    }

    var selectedNode: FileNodeRecord? {
        store?.node(id: selectedNodeID)
    }

    var hoveredNode: FileNodeRecord? {
        store?.node(id: hoveredNodeID)
    }

    // MARK: - Treemap coloring

    /// Branch-hue mode is shared by the sunburst and the flat treemap — the
    /// two structural views draw the same colors: active on the Largest tab,
    /// or whenever the statistics panel (the kind/age legend) is hidden.
    var showsBranchColors: Bool {
        let branchCapableView = vizViewMode == .sunburst
            || (vizViewMode == .treemap && treemapStyle == .flat)
        return branchCapableView && (analysisTab == .largest || !showKindStats)
    }

    /// What treemap color means, driven by the statistics-panel tab: the Age
    /// tab colors by modification date (bucketed against the scan date, so
    /// the map matches the tab's legend), every other tab colors by kind.
    /// The mode survives hiding the panel — the panel is the legend, not the
    /// owner of the state. Exception: the flat style reverts to the
    /// sunburst's branch hues on the Largest tab or with the panel hidden,
    /// exactly like the sunburst does.
    var treemapColorMode: TreemapColorMode {
        if treemapStyle == .flat, analysisTab == .largest || !showKindStats {
            return .branch
        }
        guard analysisTab == .age else { return .kind }
        let referenceDate = ages.catalog.stats.isEmpty
            ? coordinator.snapshot.map { $0.finishedAt ?? $0.startedAt }
            : ages.catalog.referenceDate
        guard let referenceDate else { return .kind }
        return .age(referenceDate: referenceDate)
    }

    /// The active tab's drill-in highlight, if any — only the visible tab's
    /// selection reaches the map, so switching tabs never leaves a stale dim.
    var treemapHighlight: TreemapHighlight? {
        switch analysisTab {
        case .kinds:
            return kinds.highlightedKindID.map { .kind($0) }
        case .largest:
            // No dim: the plain selection ring already ties a clicked row to
            // its cell, and the map keeps kind colors.
            return nil
        case .age:
            return ages.highlightedBucket.map { .ageBucket($0) }
        case .duplicates:
            return duplicates.highlightedNodeIDs.map { .nodes($0) }
        case .changes:
            // No dim, like Largest: the plain selection ring already ties a
            // clicked change to its cell, and the map keeps kind colors.
            return nil
        }
    }

    /// The active visualization palette, driven by the colorblind Settings
    /// toggle. Kind colors are baked into the catalog (see KindStatsModel);
    /// age and status-bar swatch colors read this live.
    var vizPalette: VizPalette {
        preferences?.useColorblindPalette == true ? .colorblind : .standard
    }

    /// The swatch color a node renders with on the map right now — the
    /// status bar's swatch must agree with the active view and color mode.
    /// In branch mode (sunburst or flat treemap, Largest tab or hidden
    /// statistics panel) that is the branch hue; every other combination
    /// keeps the kind/age semantics.
    func displayColor(for node: FileNodeRecord) -> Color {
        if showsBranchColors, let store {
            return SunburstColorResolver.branchColor(
                forNodeID: node.id,
                in: store,
                effectiveRootID: effectiveRootID ?? store.root.id,
                palette: vizPalette,
                // The flat treemap tints files with the branch hue; the
                // sunburst keeps its file gray.
                mutedFiles: vizViewMode == .treemap
            )
        }
        if case .age(let referenceDate) = treemapColorMode {
            guard FileKindClassifier.isLeafLike(node) else {
                let rgb = FileKindCatalog.directoryRGB
                return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            }
            return vizPalette.ageColor(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
        }
        return kinds.catalog.color(for: node)
    }

    // MARK: - Scanning

    /// Selection, zoom, and per-snapshot UI state reset before a new scan
    /// or snapshot takes the screen. Internal (not private): the caller is
    /// the scan session, whose branches decide when a new scan takes over.
    func resetPerScanState() {
        selectedNodeID = nil
        hoveredNodeID = nil
        zoomRootID = nil
        expandedNodeIDs = []
        expandedAggregateIDs = []
        kinds.reset()
        largest.reset()
        ages.reset()
        changes.reset()
        scanWasStopped = false
        warnings.reset()
    }

    private func bindPreferences() {
        guard let preferences else { return }
        session.preferences = preferences
        freeSpace.preferences = preferences
        preferencesCancellable = preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.freeSpace.update()
                self?.syncVizPalette()
                self?.syncVizViewMode()
                self?.syncTreemapStyle()
                self?.syncCloudOnlyPreference()
            }
        freeSpace.update()
        syncVizPalette()
        syncVizViewMode()
        syncTreemapStyle()
        syncCloudOnlyPreference()
    }

    /// Mirror the persisted treemap style onto the model so the treemap pane
    /// and breadcrumb re-render when the Settings picker flips.
    private func syncTreemapStyle() {
        guard let preferences else { return }
        if treemapStyle != preferences.treemapStyle {
            treemapStyle = preferences.treemapStyle
        }
    }

    private func syncCloudOnlyPreference() {
        guard let preferences else { return }
        if showCloudOnlyFilesPreferred != preferences.showCloudOnlyFiles {
            showCloudOnlyFilesPreferred = preferences.showCloudOnlyFiles
        }
    }

    /// Mirror the persisted view-mode preference onto the model so the
    /// workspace and status bar follow the toolbar switcher.
    private func syncVizViewMode() {
        guard let preferences else { return }
        if vizViewMode != preferences.vizViewMode {
            vizViewMode = preferences.vizViewMode
        }
    }

    /// Push the palette to the kind catalog when the colorblind toggle flips.
    /// Kind colors are baked at build time, so the catalog rebuilds; age and
    /// treemap colors update reactively as views re-read `vizPalette`.
    private func syncVizPalette() {
        let palette = vizPalette
        if kinds.palette != palette {
            kinds.palette = palette
        }
    }

    /// Stops the running scan, keeping any partial results on screen. The
    /// scan strip stays up offering Resume when there is something to show.
    func stopScan() {
        let hadPartialResults = coordinator.snapshot != nil
        coordinator.stopScan()
        scanWasStopped = hadPartialResults
    }

    /// Rescans the stopped target from scratch (the engine has no traversal
    /// checkpointing, so "resume" is a fresh scan of the same location).
    func resumeScan() {
        guard let target = coordinator.selectedTarget else {
            scanWasStopped = false
            return
        }
        startScan(target, forcesRescan: true)
    }

    func dismissWelcome() {
        showWelcomeSheet = false
        preferences?.hasSeenWelcome = true
    }

    /// Rescans whatever location is currently open — the explicit ask that
    /// overrides the skipped auto-rescan of a large cached location.
    func rescan() {
        guard let target = coordinator.selectedTarget, !coordinator.isScanning else { return }
        startScan(target, forcesRescan: true)
    }

    /// Opens a "smaller items" cell: its folder's children render
    /// individually from now on.
    func expandAggregate(inFolder folderID: String) {
        expandedAggregateIDs.insert(folderID)
    }

    /// Adds a folder to the sidebar (persisted) and starts scanning it.
    /// Built-in locations (volumes and cloud) are already in the sidebar
    /// and never join the Folders section.
    func chooseFolderAndScan() {
        guard let target = SystemIntegration.presentScanPanel() else { return }
        let isBuiltInLocation = builtInLocations.contains { $0.id == target.id }
        if !isBuiltInLocation, !sidebarFolders.contains(where: { $0.id == target.id }) {
            sidebarFolders.append(target)
            sidebarFolderStore.add(target)
        }
        startScan(target)
    }

    /// Handles folders dropped onto the window or the sidebar: adds each
    /// one to the Folders section (same rules as Add Folder… — built-in
    /// locations and duplicates are skipped) and starts scanning the
    /// first. Non-folder drops are ignored.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        let folderURLs = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folderURLs.isEmpty else { return false }

        let builtInIDs = Set(builtInLocations.map(\.id))
        var firstTarget: ScanTarget?
        for url in folderURLs {
            let target = ScanTarget(url: url)
            if firstTarget == nil { firstTarget = target }
            if !builtInIDs.contains(target.id),
               !sidebarFolders.contains(where: { $0.id == target.id }) {
                sidebarFolders.append(target)
                sidebarFolderStore.add(target)
            }
        }
        if let firstTarget {
            startScan(firstTarget)
        }
        return true
    }

    func removeSidebarFolders(ids: Set<String>) {
        for target in sidebarFolders where ids.contains(target.id) {
            sidebarFolderStore.remove(target)
        }
        sidebarFolders.removeAll { ids.contains($0.id) }

        // A removed folder loses its persisted snapshot too — unless it is
        // also a built-in location, which keeps its own cache entry.
        let removedIDs = ids.subtracting(builtInLocations.map(\.id))
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs {
            session.removeCachedScanInfo(forTargetID: id)
            coordinator.forgetRecentSnapshot(forTargetID: id)
        }
        Task { [snapshotCache] in
            for id in removedIDs {
                await snapshotCache.removeSnapshot(forTargetID: id)
            }
        }
    }

    private func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        freeSpace.update()

        diff.snapshotDidChange(snapshot)

        // The kind and age catalogs, the drilled-in lists, and the shared
        // search index are all keyed to the replaced tree.
        searchIndexService.invalidate()
        kinds.snapshotDidChange(snapshot)
        largest.snapshotDidChange()
        ages.snapshotDidChange(snapshot)
        duplicates.snapshotDidChange()
        changes.snapshotDidChange()
        search.snapshotDidChange()

        guard let snapshot else { return }

        // Expand the root row by default so the outline isn't a single line.
        expandedNodeIDs.insert(snapshot.treeStore.root.id)
    }

    // MARK: - Subtree refresh

    /// Gate for the context-menu subtree action: nothing else may be
    /// scanning, restoring, or expanding.
    var canRefreshSubtree: Bool {
        !coordinator.isScanning
            && coordinator.phase != .restoring
            && coordinator.expandingNodeID == nil
    }

    /// The contents-expansion context-menu command a node offers, if any.
    /// Both kinds funnel into `expandNodeContents`; only the wording (and
    /// the reason the contents are missing) differs.
    enum ContentsExpansion {
        /// An auto-summarized folder — "Expand Contents".
        case summarizedFolder
        /// A still-opaque package — Finder's "Show Package Contents".
        case package

        var menuTitleKey: String {
            switch self {
            case .summarizedFolder: "Expand Contents"
            case .package: "Show Package Contents"
            }
        }
    }

    /// The expansion command to offer `node` in a context menu, or nil.
    /// Every menu (outline, treemap, sunburst chart + legend, file lists)
    /// derives its item from this one gate so they cannot drift. An already
    /// expanded package has children in the store and offers nothing.
    func contentsExpansion(for node: FileNodeRecord) -> ContentsExpansion? {
        if node.isAutoSummarized { return .summarizedFolder }
        if node.isPackage, node.isDirectory, store?.containsChildren(id: node.id) != true {
            return .package
        }
        return nil
    }

    /// Scans an auto-summarized folder's or an opaque package's real
    /// contents and splices them in — the context menu's "Expand Contents" /
    /// "Show Package Contents".
    func expandNodeContents(_ node: FileNodeRecord) {
        guard canRefreshSubtree else { return }
        // Match the on-screen scan's options (a volume scan forces hidden
        // files on) so the spliced subtree isn't missing entries it had.
        var options = coordinator.snapshot.map { session.scanOptions(for: $0.target) }
            ?? preferences?.scanOptions ?? ScanOptions()
        if node.isAutoSummarized {
            // The user explicitly asked for this folder's contents;
            // re-summarizing it would make the action a no-op.
            options.autoSummarizeDirectories = false
        } else {
            // Show Package Contents: open this one package — bundles nested
            // inside stay opaque (each individually expandable), and huge
            // interior folders may still auto-summarize per the usual rules.
            options.treatRootPackageAsDirectory = true
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.coordinator.expandNodeContents(node, options: options)
            self.handleSubtreeRefresh(result)
        }
    }

    private func handleSubtreeRefresh(_ result: ScanExpansionResult) {
        switch result {
        case .expanded(let replacementRootID):
            revealInOutline(replacementRootID)
            expandedNodeIDs.insert(replacementRootID)
            session.persistSplicedSnapshot()
        case .failed(let message):
            actionErrorMessage = message
        case .skipped, .cancelled:
            break
        }
    }

}
