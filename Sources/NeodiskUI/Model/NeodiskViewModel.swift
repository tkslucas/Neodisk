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
import NeodiskAppModel

@MainActor
@Observable
final class NeodiskViewModel {
    let coordinator: ScanCoordinator

    /// Every selected item, one of them primary; see NodeSelection. Lists and maps write it, every view reads it.
    var selection = NodeSelection() {
        didSet {
            guard selection.revision != oldValue.revision else { return }
            // Any selection — from the treemap, outline, sidebar lists, or
            // search — keeps its primary on screen: if it lands outside a
            // drilled-in map, widen the root out to reveal it. Done here, not
            // in select(), because the lists write the selection directly.
            if let primaryID = selection.primaryID, primaryID != oldValue.primaryID {
                widenRootToShow(primaryID)
            }
            // Live-update an open Quick Look panel as the selection moves
            // (arrow-keying through the outline). No-op when it's closed.
            QuickLookPresenter.shared.selectionDidChange(to: selectedNodes, current: selectedNode)
        }
    }

    /// The primary selected item: what single-item features (drilling, arrow keys, the breadcrumb) act on.
    var selectedNodeID: String? { selection.primaryID }

    private(set) var visualizationHover: VisualizationHover?

    /// Publish a complete hover identity in one observation transaction.
    /// Re-entering the same cell/segment is a true no-op.
    @discardableResult
    func setVisualizationHover(_ hover: VisualizationHover?) -> Bool {
        guard visualizationHover != hover else { return false }
        visualizationHover = hover
        return true
    }

    var hoveredNodeID: String? { visualizationHover?.nodeID }
    /// Set while the cursor is over a merged "smaller items" cell;
    /// `hoveredNodeID` then points at the containing folder.
    var hoveredAggregate: TreemapCell.AggregateInfo? {
        guard case .aggregate(_, let itemCount, let totalSize, _) = visualizationHover else {
            return nil
        }
        return TreemapCell.AggregateInfo(itemCount: itemCount, totalSize: totalSize)
    }
    var hoveredCellIsFreeSpace: Bool {
        guard case .freeSpace = visualizationHover else { return false }
        return true
    }
    var hoveredCellIsHiddenSpace: Bool {
        guard case .hiddenSpace = visualizationHover else { return false }
        return true
    }
    /// Node the treemap is currently zoomed into; nil means the snapshot root.
    var zoomRootID: String? {
        didSet {
            // Every re-root, whichever surface drove it, is a step Go > Back
            // can return to — except the steps Back/Forward take themselves.
            guard zoomRootID != oldValue, !isSteppingDrillHistory, let store else { return }
            drillHistory.recordLeaving(oldValue ?? store.root.id)
        }
    }
    /// Go > Back/Forward over the drill roots; cleared per scan.
    var drillHistory = DrillHistory()
    @ObservationIgnored var isSteppingDrillHistory = false
    /// Folders whose "smaller items" cell the user clicked open — their
    /// children render individually even when tiny.
    var expandedAggregateIDs: Set<String> = []
    var showKindStats = true {
        didSet { syncDiffVisibility() }
    }
    /// Which statistics-panel tab is active. Also decides what treemap color
    /// means (Age colors by modification date; the others keep kind colors)
    /// and which drill-in highlight reaches the map — see vizColorMode /
    /// vizHighlight. Deliberately not reset per scan: the chosen lens
    /// carries across locations. Starts on Largest — the first tab, and the
    /// first question a disk tool gets asked.
    var analysisTab: AnalysisTab = .largest {
        didSet { syncDiffVisibility() }
    }
    /// Mirror of the persisted tab order and visibility; change it through setAnalysisTabs.
    private(set) var analysisTabs = ItemLayout<AnalysisTab>()
    /// Mirror of the bottom table's persisted column order and visibility.
    private(set) var outlineColumns = ItemLayout<OutlineColumn>(pinned: .name)
    /// Locations sidebar visibility; lives here so the View menu can toggle
    /// it. Always starts visible.
    var sidebarVisibility = NavigationSplitViewVisibility.all
    /// Mirror of the sidebar's persisted hidden and collapsed sections; change it through setSidebarSection.
    private(set) var sidebarSections = SidebarSectionState()
    /// Set by the toolbar's Cleanup button; the panel pulses so the eye finds it, then clears it.
    var isCleanupRevealPending = false
    /// Mirror of the persisted WorkspaceLayout: the view, the picker's views and each view's file list. The diff
    /// stays armed across a switch to Sunburst, so switching back keeps it.
    private(set) var layout = WorkspaceLayout()
    var vizViewMode: VizViewMode {
        get { layout.mode }
        set { layout.mode = newValue }
    }
    var treemapStyle: TreemapStyle {
        get { layout.treemapStyle }
        set { layout.treemapStyle = newValue }
    }
    var showsStatusBar = false
    /// The main window is on screen; menu commands that act on it disable while it's closed.
    var isWindowOpen = false
    /// Mirror of the bottom table's persisted header sort, synced by
    /// bindPreferences. The left column ignores it (fixed size order).
    var outlineSort = OutlineSort(field: .size, ascending: false)
    /// Dev hooks pin their forced layout for the run; otherwise the next preferences change would undo it.
    @ObservationIgnored var devLayoutOverride: ((inout WorkspaceLayout) -> Void)?
    /// The same for the sidebar's sections.
    @ObservationIgnored var devSidebarSectionsOverride: ((inout SidebarSectionState) -> Void)?
    /// Mirror of the persisted workspace text scale, synced by
    /// bindPreferences — same pattern as treemapStyle. The workspace root
    /// puts it in the environment for SwiftUI; the AppKit surfaces that draw
    /// their own text (outline table, treemap labels) read it from here.
    var textScale: Double = TextScale.standard

    // MARK: Cleanup

    /// Items collected for the Trash; see CleanupModel.
    let cleanup: CleanupModel

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

    private(set) var expandedNodeIDs: Set<String> = []
    /// Changes only when the expansion set actually changes. Outline row
    /// caches key off this scalar instead of hashing every expanded ID on
    /// each selection update.
    private(set) var outlineExpansionRevision: UInt64 = 0
    @ObservationIgnored let outlineRowsCache = OutlineRowsCache()

    func replaceExpandedOutlineNodes(with nodeIDs: Set<String>) {
        guard expandedNodeIDs != nodeIDs else { return }
        expandedNodeIDs = nodeIDs
        outlineExpansionRevision &+= 1
    }

    func expandOutlineNodes<S: Sequence>(_ nodeIDs: S) where S.Element == String {
        var expanded = expandedNodeIDs
        expanded.formUnion(nodeIDs)
        replaceExpandedOutlineNodes(with: expanded)
    }
    /// An error shown to the user as an alert; every one is also logged.
    var actionErrorMessage: String? {
        didSet {
            if let actionErrorMessage { DiagnosticLog.app.error("shown to user: \(actionErrorMessage)") }
        }
    }
    /// True after the user stops a scan mid-flight while partial results are
    /// on screen: the scan strip stays visible offering Resume.
    var scanWasStopped = false
    /// Shows the first-launch welcome sheet (also reachable from Settings).
    var showWelcomeSheet = false
    /// A first scan held while the window offers Full Disk Access; starting any scan clears it.
    private(set) var fullDiskAccessGate: ScanTarget?

    // MARK: Scan warnings

    /// Notice-strip warning visibility, popover grouping, and the Full
    /// Disk Access probe; see ScanWarningsModel.
    let warnings: ScanWarningsModel
    /// The sidebar's Folders section: seeded with the common folders on
    /// first launch, extended by Add Folder, every entry removable.
    var sidebarFolders: [ScanTarget] = []
    /// The Folders rows the user added, not the common ones the section starts with.
    var addedSidebarFolders: [ScanTarget] {
        let commonIDs = Set(sidebarFolderStore.commonFolders.map(\.id))
        return sidebarFolders.filter { !commonIDs.contains($0.id) }
    }
    /// True when a common folder was removed, so Settings can bring it back.
    var isMissingCommonSidebarFolders: Bool {
        let ids = Set(sidebarFolders.map(\.id))
        return sidebarFolderStore.commonFolders.contains { !ids.contains($0.id) }
    }
    /// Mounted volumes shown in the sidebar's Volumes section.
    let volumeLocations = SystemIntegration.volumeTargets()
    /// Locally-synced cloud storage folders (iCloud Drive, File Provider
    /// roots), shown in the sidebar's own "Local Cloud Files" section.
    let cloudLocations = SystemIntegration.cloudTargets()
    /// The fixed sidebar locations (volumes, local cloud folders): unlike
    /// the Folders section these can never be removed.
    var builtInLocations: [ScanTarget] { volumeLocations + cloudLocations }

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

    /// Volume free space and hidden space; see
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
        snapshotCache: ScanSnapshotCache,
        sidebarFolderStore: SidebarFolderStore = SidebarFolderStore()
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.sidebarFolderStore = sidebarFolderStore
        self.warnings = ScanWarningsModel(coordinator: coordinator)
        self.freeSpace = FreeSpaceModel(coordinator: coordinator)
        self.cleanup = CleanupModel(coordinator: coordinator)
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
        session.model = self
        cleanup.model = self

        // The coordinator is @Observable, so views track its properties
        // (phase, snapshot, …) directly; the model only needs the snapshot
        // change hook for its own bookkeeping.
        coordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshotDidChange(snapshot)
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
    func startScan(_ target: ScanTarget, forcesRescan: Bool = false, previewOnly: Bool = false) {
        fullDiskAccessGate = nil
        session.startScan(target, forcesRescan: forcesRescan, previewOnly: previewOnly)
    }

    /// A location the user picked. Without Full Disk Access its first scan would stop at one macOS prompt per
    /// protected folder, so it offers access first, until the user chooses Scan Anyway.
    func startChosenScan(_ target: ScanTarget) {
        guard preferences?.scansWithoutFullDiskAccess == false,
              warnings.fullDiskAccessStatus == .notGranted,
              session.hasIndexedSnapshotCache, session.cachedScanInfo[target.id] == nil,
              coordinator.recentSnapshot(forTargetID: target.id) == nil,
              PermissionPromptWatch.reachesProtectedFolder(target.url.path) else {
            startScan(target)
            return
        }
        fullDiskAccessGate = target
    }

    /// Scan Anyway (remembered), or access granted while the offer was up.
    func passFullDiskAccessGate(remembering: Bool) {
        guard let target = fullDiskAccessGate else { return }
        if remembering { preferences?.scansWithoutFullDiskAccess = true }
        startScan(target)
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

    // MARK: - Visualization coloring

    /// Branch-hue mode is shared by every visualization — sunburst and both
    /// treemap styles draw the same structural colors: active on the Largest
    /// tab, or whenever the statistics panel (the kind/age legend) is hidden.
    var showsBranchColors: Bool {
        analysisTab == .largest || !showKindStats
    }

    /// What visualization color means, driven by the statistics-panel tab:
    /// the Age tab colors by modification date (bucketed against the scan
    /// date, so the map matches the tab's legend), every other tab colors by
    /// kind — and without a kind/age legend on screen (the Largest tab, or
    /// the panel hidden) every view reverts to the structural branch hues.
    var vizColorMode: TreemapColorMode {
        if showsBranchColors { return .branch }
        guard analysisTab == .age else { return .kind }
        let referenceDate = ages.catalog.stats.isEmpty
            ? coordinator.snapshot.map { $0.finishedAt ?? $0.startedAt }
            : ages.catalog.referenceDate
        guard let referenceDate else { return .kind }
        return .age(referenceDate: referenceDate)
    }

    /// The active tab's drill-in highlight, if any — only the visible tab's
    /// selection reaches the map, so switching tabs never leaves a stale
    /// dim. Branch mode carries no highlight: its states (Largest tab,
    /// hidden panel) have no kind/age legend to dim against.
    var vizHighlight: TreemapHighlight? {
        guard !showsBranchColors else { return nil }
        switch analysisTab {
        case .kinds:
            return kinds.highlightedKindID.map { .kind($0) }
        case .largest:
            return nil
        case .age:
            return ages.highlightedBucket.map { .ageBucket($0) }
        case .duplicates:
            return duplicates.highlightedNodeIDs.map { .nodes($0) }
        case .changes:
            // No dim: the plain selection ring already ties a clicked
            // change to its cell.
            return nil
        }
    }

    /// The active visualization palette, driven by the Settings picker.
    /// Kind colors are baked into the catalog (see KindStatsModel); age and
    /// status-bar swatch colors read this live.
    var vizPalette: VizPalette {
        preferences?.vizPalette ?? .standard
    }

    /// The swatch color a node renders with on the map right now — the
    /// status bar's swatch must agree with the active view and color mode.
    /// In branch mode (Largest tab or hidden statistics panel) that is the
    /// branch hue; every other combination keeps the kind/age semantics.
    func displayColor(for node: FileNodeRecord) -> Color {
        if showsBranchColors, let store {
            return SunburstColorResolver.branchColor(
                forNodeID: node.id,
                in: store,
                palette: vizPalette,
                includingCloudOnly: showsCloudOnlyFiles,
                // Both treemap styles tint files with the branch hue; the
                // sunburst keeps its file gray.
                branchTintedFiles: vizViewMode == .treemap
            )
        }
        if case .age(let referenceDate) = vizColorMode {
            guard FileKindClassifier.isLeafLike(node) else {
                return Color(rgb: FileKindCatalog.directoryRGB)
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
        selection.clear()
        setVisualizationHover(nil)
        zoomRootID = nil
        drillHistory = DrillHistory()
        replaceExpandedOutlineNodes(with: [])
        expandedAggregateIDs = []
        kinds.reset()
        largest.reset()
        ages.reset()
        changes.reset()
        scanWasStopped = false
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
                self?.syncWorkspaceLayout()
                self?.syncCloudOnlyPreference()
                self?.syncOutlinePreferences()
                self?.syncLayoutPreferences()
                self?.syncTextScale()
                self?.syncFileCategories()
                self?.syncCleanupPreference()
                self?.syncSidebarSections()
            }
        freeSpace.update()
        syncVizPalette()
        syncWorkspaceLayout()
        syncCloudOnlyPreference()
        syncOutlinePreferences()
        syncLayoutPreferences()
        syncTextScale()
        syncFileCategories()
        syncCleanupPreference()
        syncSidebarSections()
    }

    private func syncCleanupPreference() {
        guard let preferences else { return }
        cleanup.setEnabled(preferences.allowsMovingToTrash)
    }

    // MARK: Sidebar sections

    func syncSidebarSections() {
        guard let preferences else { return }
        var mirrored = preferences.sidebarSections
        devSidebarSectionsOverride?(&mirrored)
        if sidebarSections != mirrored { sidebarSections = mirrored }
    }

    func isSidebarSectionShown(_ section: SidebarSection) -> Bool {
        sidebarSections.isShown(section, cleanupEnabled: cleanup.isEnabled)
    }

    /// Showing or hiding Cleanup turns moving to the Trash on or off, as in Settings.
    func setSidebarSection(_ section: SidebarSection, shown: Bool) {
        updateSidebarSections { $0.setShown(section, shown) }
    }

    func setSidebarSection(_ section: SidebarSection, expanded: Bool) {
        updateSidebarSections { $0.setExpanded(section, expanded) }
    }

    /// The toolbar's Cleanup button: the sidebar opens and Cleanup expands.
    func revealCleanup() {
        if sidebarVisibility == .detailOnly {
            withAnimation { sidebarVisibility = .all }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            updateSidebarSections { $0.reveal(.cleanup) }
        }
        isCleanupRevealPending = true
    }

    private func updateSidebarSections(_ change: (inout SidebarSectionState) -> Void) {
        var sections = sidebarSections
        change(&sections)
        guard sections != sidebarSections else { return }
        sidebarSections = sections
        preferences?.sidebarSections = sections
    }

    /// Before items leave the tree: a selection or drill root inside one moves to the folder that held it, so
    /// the views land somewhere that still exists.
    func prepareForRemoval(of removedIDs: [String], in store: FileTreeStore) {
        let removed = Set(removedIDs)
        if let zoomRootID, let kept = store.survivor(of: zoomRootID, removing: removed), kept != zoomRootID {
            self.zoomRootID = kept == store.rootID ? nil : kept
        }
        selection.prepareForRemoval(of: removed, in: store)
    }

    /// Mirror the persisted text scale onto the model, and push it into the
    /// AppKit outline metrics, which have no environment to read from.
    private func syncTextScale() {
        guard let preferences else { return }
        let scale = preferences.textScale
        guard textScale != scale else { return }
        textScale = scale
        OutlineRowMetrics.scale = CGFloat(scale)
    }

    // MARK: Text size

    var canZoomTextIn: Bool { TextScale.larger(than: textScale) != nil }
    var canZoomTextOut: Bool { TextScale.smaller(than: textScale) != nil }
    var isTextSizeStandard: Bool { textScale == TextScale.standard }

    func zoomTextIn() {
        guard let next = TextScale.larger(than: textScale) else { return }
        preferences?.textScale = next
    }

    func zoomTextOut() {
        guard let next = TextScale.smaller(than: textScale) else { return }
        preferences?.textScale = next
    }

    func resetTextSize() {
        preferences?.textScale = TextScale.standard
    }

    private func syncCloudOnlyPreference() {
        guard let preferences else { return }
        if showCloudOnlyFilesPreferred != preferences.showCloudOnlyFiles {
            showCloudOnlyFilesPreferred = preferences.showCloudOnlyFiles
        }
    }

    /// Mirror the persisted outline presentation and bottom-table sort so
    /// the workspace re-lays-out when Settings, the View menu, or a column
    /// header changes them.
    private func syncOutlinePreferences() {
        guard let preferences else { return }
        if outlineSort != preferences.outlineSort {
            outlineSort = preferences.outlineSort
        }
    }

    private func syncLayoutPreferences() {
        guard let preferences else { return }
        if outlineColumns != preferences.outlineColumns {
            outlineColumns = preferences.outlineColumns
        }
        if analysisTabs != preferences.analysisTabs {
            analysisTabs = preferences.analysisTabs
        }
        // A hidden tab can't stay the lens: the map would color by a tab nobody can see.
        if analysisTabs.isHidden(analysisTab) { analysisTab = analysisTabs.shown(analysisTab) }
    }

    func setAnalysisTabs(_ layout: ItemLayout<AnalysisTab>) {
        preferences?.analysisTabs = layout
        analysisTabs = layout
        if layout.isHidden(analysisTab) { analysisTab = layout.shown(analysisTab) }
    }

    // MARK: Views and panels

    var vizView: VizView { layout.view }

    /// Changes the persisted layout through WorkspaceLayout's rules; the mirror follows at once.
    func updateLayout(_ change: (inout WorkspaceLayout) -> Void) {
        guard let preferences else { return }
        var updated = preferences.workspaceLayout
        change(&updated)
        preferences.workspaceLayout = updated
        syncWorkspaceLayout()
    }

    func setStatusBarShown(_ shown: Bool) {
        preferences?.showStatusBar = shown
        syncWorkspaceLayout()
    }

    func syncWorkspaceLayout() {
        guard let preferences else { return }
        var mirrored = preferences.workspaceLayout
        devLayoutOverride?(&mirrored)
        if layout != mirrored { layout = mirrored }
        if showsStatusBar != preferences.showStatusBar { showsStatusBar = preferences.showStatusBar }
    }

    func setOutlineColumns(_ layout: ItemLayout<OutlineColumn>) {
        preferences?.outlineColumns = layout
        outlineColumns = layout
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

    /// Put the persisted category customization in effect. When it changes
    /// what files are filed under, everything holding categories redoes
    /// them: the kind catalog (and the map colors it carries), the search
    /// index's per-node kinds, and the displayed scan's persisted stats.
    private func syncFileCategories() {
        guard let preferences,
              FileCategoryRules.install(preferences.fileCategories) else { return }
        searchIndexService.invalidate()
        kinds.categoryRulesDidChange()
        session.categoryRulesDidChange()
    }

    /// Changes the category customization (the Kinds tab's menus, Settings).
    func updateFileCategories(_ change: (inout FileCategoryCustomization) -> Void) {
        guard let preferences else { return }
        var customization = preferences.fileCategories
        change(&customization)
        preferences.fileCategories = customization
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
        guard canRescan, let target = coordinator.selectedTarget else { return }
        startScan(target, forcesRescan: true)
    }

    /// Rescan acts on the scan on screen: none while the Full Disk Access offer covers it, else Rescan would
    /// leave the picked location for the one behind the offer.
    var canRescan: Bool {
        fullDiskAccessGate == nil && coordinator.canRescan && coordinator.snapshot != nil
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
        Task { await addFolderFromPanel() }
    }

    private func addFolderFromPanel() async {
        guard let target = await SystemIntegration.presentScanPanel() else { return }
        let isBuiltInLocation = builtInLocations.contains { $0.id == target.id }
        if !isBuiltInLocation, !sidebarFolders.contains(where: { $0.id == target.id }) {
            sidebarFolders.append(target)
            sidebarFolderStore.add(target)
        }
        startChosenScan(target)
    }

    /// Handles folders dropped onto the window or the sidebar: adds each
    /// one to the Folders section (same rules as Add Folder… — built-in
    /// locations and duplicates are skipped) and starts scanning the
    /// first. Non-folder drops are ignored, and so are the app's own items: a drag that started in a map or list
    /// and slipped is not a request to add a location.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        guard !cleanup.isDragInProgress else { return false }
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
            startChosenScan(firstTarget)
        }
        return true
    }

    /// With an undo manager (the sidebar) the removal is undoable and the saved scans stay, so Undo or adding the
    /// folder again brings them back; the next launch's prune drops them if the folder is still gone. Without one
    /// (Settings' Clear Added Folders) they go now.
    func removeSidebarFolders(ids requestedIDs: Set<String>, undoManager: UndoManager? = nil) {
        // A location with a scan in flight (foreground or a demoted background
        // scan) must not be pulled out from under it — dropping its cache mid-
        // scan would orphan the session. Refuse those; Stage 3 disables the UI.
        let ids = requestedIDs.filter { session.activeSession(forTargetID: $0) == nil }
        let removed = sidebarFolders.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }

        for (_, target) in removed {
            sidebarFolderStore.remove(target)
        }
        sidebarFolders.removeAll { ids.contains($0.id) }

        // The location on screen left the sidebar: back to the empty state, so nothing on screen (Rescan
        // included) points at a location that's no longer listed. A built-in one is still listed. Undo puts the row
        // back; its scan is kept, so picking it shows the scan again at once.
        if let shown = coordinator.selectedTarget?.id, ids.contains(shown),
           !builtInLocations.contains(where: { $0.id == shown }) {
            session.dismissSnapshotNotice()
            resetPerScanState()
            coordinator.clearScan()
        }

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.restoreSidebarFolders(removed.map { ($0.offset, $0.element) }, undoManager: undoManager)
                }
            }
            undoManager.setActionName(NSLocalizedString("Remove from Sidebar", comment: "Undo action"))
            return
        }

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

    /// Settings' Clear Added Folders: the common folders stay.
    func removeAddedSidebarFolders() {
        removeSidebarFolders(ids: Set(addedSidebarFolders.map(\.id)))
    }

    func restoreCommonSidebarFolders() {
        sidebarFolders = sidebarFolderStore.restoreCommonFolders(keeping: sidebarFolders)
    }

    /// Undo of a sidebar removal: each folder back where it was; Redo removes them again.
    private func restoreSidebarFolders(_ removed: [(index: Int, target: ScanTarget)], undoManager: UndoManager) {
        for (index, target) in removed where !sidebarFolders.contains(where: { $0.id == target.id }) {
            sidebarFolders.insert(target, at: min(index, sidebarFolders.count))
        }
        sidebarFolderStore.save(sidebarFolders)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.removeSidebarFolders(ids: Set(removed.map(\.target.id)), undoManager: undoManager)
            }
        }
        undoManager.setActionName(NSLocalizedString("Remove from Sidebar", comment: "Undo action"))
    }

    /// The location of the last displayed tree, so a newer tree of the same
    /// location (partials, the final tree) can keep list rows on screen.
    @ObservationIgnored private var lastSnapshotTargetID: String?

    private func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        freeSpace.update()
        let isSameLocation = snapshot != nil && snapshot?.target.id == lastSnapshotTargetID
        lastSnapshotTargetID = snapshot?.target.id

        diff.snapshotDidChange(snapshot)

        // The kind and age catalogs, the drilled-in lists, and the shared
        // search index are all keyed to the replaced tree.
        searchIndexService.invalidate()
        kinds.snapshotDidChange(snapshot)
        largest.snapshotDidChange(keepingRows: isSameLocation)
        ages.snapshotDidChange(snapshot)
        duplicates.snapshotDidChange()
        changes.snapshotDidChange()
        search.snapshotDidChange()
        cleanup.snapshotDidChange(snapshot)

        guard let snapshot else { return }

        // A newer tree of the same location keeps the selection by path; what's gone leaves it.
        if isSameLocation, snapshot.isComplete {
            selection.reconcile(with: snapshot.treeStore)
        }

        // Expand the root row by default so the outline isn't a single line.
        expandOutlineNodes([snapshot.treeStore.root.id])
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
            revealInOutline(replacementRootID, includingNode: true)
            session.persistSplicedSnapshot()
        case .failed(let message):
            actionErrorMessage = message
        case .skipped, .cancelled:
            break
        }
    }

}
