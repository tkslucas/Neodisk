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
    /// Warnings the user closed in the floating panel. Reset when a new
    /// scan starts, so a rescan resurfaces still-current warnings.
    var dismissedWarningIDs: Set<ScanWarning.ID> = []

    /// Latest Full Disk Access probe result. With access granted, the
    /// permission-denied warnings that remain are dead ends the user cannot
    /// fix (other users' home folders, SIP-protected system paths), so the
    /// warning surfaces hide them. Refreshed on launch and app activation.
    var fullDiskAccessStatus: FullDiskAccessStatus = .unknown

    func refreshFullDiskAccessStatus() async {
        fullDiskAccessStatus = await Task.detached(priority: .utility) {
            SystemIntegration.fullDiskAccessStatus()
        }.value
    }

    /// Scan warnings still visible in the floating panel (capped to keep the
    /// panel responsive on scans with thousands of skipped items).
    var visibleScanWarnings: [ScanWarning] {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return [] }
        let hidePermissionDenied = fullDiskAccessStatus == .granted
        // Eager loop: a lazy filter whose predicate mutates state (the seen-ID
        // dedupe) violates Collection semantics and traps inside prefix(_:).
        var seenIDs = Set<ScanWarning.ID>()
        var visible: [ScanWarning] = []
        for warning in snapshot.scanWarnings {
            if hidePermissionDenied && warning.category == .permissionDenied { continue }
            // Warning identity is content-derived, so repeat warnings for the
            // same path collapse to one row.
            guard !dismissedWarningIDs.contains(warning.id),
                  seenIDs.insert(warning.id).inserted else { continue }
            visible.append(warning)
            if visible.count == 100 { break }
        }
        return visible
    }

    func dismissWarning(_ id: ScanWarning.ID) {
        dismissedWarningIDs.insert(id)
    }

    func dismissAllWarnings() {
        guard let snapshot = coordinator.snapshot else { return }
        dismissedWarningIDs.formUnion(snapshot.scanWarnings.map(\.id))
    }
    /// The sidebar's Folders section: seeded with the common folders on
    /// first launch, extended by Add Folder, every entry removable.
    var sidebarFolders: [ScanTarget] = []
    /// Mounted volumes shown in the sidebar's Volumes section.
    let volumeLocations = SystemIntegration.volumeTargets()
    /// Locally-synced cloud storage folders (iCloud Drive, File Provider
    /// roots), shown in the sidebar's own "Local Cloud Files" section.
    let cloudLocations = SystemIntegration.cloudTargets()
    /// Connected remote cloud-drive accounts (CloudScan), shown in the
    /// sidebar's "Cloud Drives" section. Seeded once from `cloudScan` at
    /// launch; empty in builds without the CloudScan feature.
    private(set) var cloudDriveAccounts: [ScanTarget] = []
    /// The fixed sidebar locations: volumes, local cloud folders, and remote
    /// cloud-drive accounts. Unlike the Folders section these can never be
    /// removed. Feeding cloud accounts through here joins them into sidebar
    /// selection (`allTargets`), dedup, and the snapshot-cache keep-list.
    var builtInLocations: [ScanTarget] { volumeLocations + cloudLocations + cloudDriveAccounts }
    /// What the snapshot cache holds per target path: which locations open
    /// instantly from cache, the sidebar's "Scanned … ago" subtitles, and
    /// how long the last scan took (whether a rescan should auto-start).
    private(set) var cachedScanInfo: [String: CachedScanInfo] = [:]
    /// Shown while a cached snapshot stands in for a skipped auto-rescan:
    /// the floating notice offering the rescan the app didn't start.
    var snapshotNotice: SnapshotNotice?

    /// Under the smart auto-rescan policy: rescans that finished faster than
    /// this last time keep the original click-to-rescan behavior; slower ones
    /// display their snapshot and leave rescanning to the user (via the
    /// notice or the toolbar).
    static let autoRescanMaxLastScanDuration: TimeInterval = 15

    struct SnapshotNotice: Equatable {
        let targetID: String
        let scanDate: Date
        let lastScanDuration: TimeInterval?
    }

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
    /// Free space of the scanned volume, when the scan target is a volume.
    /// The sunburst always renders it; the treemap keeps the Settings toggle
    /// (default off) — see `treemapFreeSpaceBytes`.
    var freeSpaceBytes: Int64?
    /// DaisyDisk-style "hidden space" of the scanned volume: capacity that is
    /// neither free nor accounted for by the finished scan (purgeable space,
    /// local snapshots, files the scan could not read). Same gates as
    /// `freeSpaceBytes`, plus a complete snapshot — mid-scan the unscanned
    /// remainder is unknown, not hidden. Drawn as a synthetic cell/arc.
    var hiddenSpaceBytes: Int64?

    /// The treemap's preference-gated view of the synthetic space: unlike
    /// the sunburst (which always shows free and hidden space for volume
    /// scans), the treemap adds them only when the Settings toggle is on.
    /// Toggle reactivity rides on bindPreferences → updateFreeSpace
    /// reassigning the stored bytes, which fires observation.
    var treemapFreeSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? freeSpaceBytes : nil
    }
    var treemapHiddenSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? hiddenSpaceBytes : nil
    }

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
    /// False until the launch prune has filled `cachedScanInfo`; before that,
    /// scans probe the cache optimistically instead of trusting the index.
    @ObservationIgnored private var hasIndexedSnapshotCache = false
    @ObservationIgnored private var preferencesCancellable: AnyCancellable?
    /// The CloudScan integration, or nil in builds without the feature. Owns
    /// the sidebar's connected accounts and the cloud scan stream.
    @ObservationIgnored private(set) var cloudScan: (any CloudScanIntegrating)?
    /// Last-known quota per cloud account, so the free-space cell renders
    /// immediately on reselect while a fresh figure is fetched.
    @ObservationIgnored private var cloudQuotaByTargetID: [String: (totalBytes: Int64?, usedBytes: Int64)] = [:]

    init(
        coordinator: ScanCoordinator = ScanCoordinator(),
        snapshotCache: ScanSnapshotCache = ScanSnapshotCache(),
        sidebarFolderStore: SidebarFolderStore = SidebarFolderStore(),
        cloudScan: (any CloudScanIntegrating)? = nil
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.sidebarFolderStore = sidebarFolderStore
        self.cloudScan = cloudScan
        self.search = SearchModel(coordinator: coordinator, indexService: searchIndexService)
        self.kinds = KindStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.largest = LargestFilesModel(coordinator: coordinator, indexService: searchIndexService)
        self.ages = AgeStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.duplicates = DuplicatesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.diff = DiffModel(coordinator: coordinator, snapshotCache: snapshotCache)
        self.changes = ChangesModel(coordinator: coordinator, snapshotCache: snapshotCache)
        sidebarFolders = sidebarFolderStore.load()
        diff.model = self
        changes.model = self

        // The coordinator is @Observable, so views track its properties
        // (phase, snapshot, …) directly; the model only needs the snapshot
        // change hook for its own bookkeeping.
        coordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshotDidChange(snapshot)
        }

        coordinator.onScanFinished = { [weak self] snapshot in
            guard let self else { return }
            self.persistCompletedSnapshot(snapshot)
            // Opt-in convenience: kick off the duplicate content scan the
            // moment a scan lands, so the Duplicates tab is ready (or at
            // least underway) by the time the user opens it.
            if self.preferences?.autoScanDuplicates == true {
                self.duplicates.startScan()
            }
        }

        // Seed the connected cloud accounts before the keep-list below is
        // computed, so their persisted snapshots survive the launch prune
        // (builtInLocations already folds cloudDriveAccounts in).
        cloudDriveAccounts = cloudScan?.accountTargets ?? []
        // Refresh the sidebar's cloud rows whenever an account is connected
        // or signed out.
        self.cloudScan?.onAccountsChanged = { [weak self] in
            self?.refreshCloudDriveAccounts()
        }

        // Drop cache entries for locations no longer in the sidebar and
        // learn which targets can open instantly from cache.
        let validTargetIDs = Set((builtInLocations + sidebarFolders).map(\.id))
        Task { [weak self, snapshotCache] in
            let index = await snapshotCache.pruneAndIndex(keepingTargetIDs: validTargetIDs)
            // A scan finishing during the prune has the newer entry — keep it.
            self?.cachedScanInfo.merge(index) { current, _ in current }
            self?.hasIndexedSnapshotCache = true
        }
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

    /// What treemap color means, driven by the statistics-panel tab: the Age
    /// tab colors by modification date (bucketed against the scan date, so
    /// the map matches the tab's legend), every other tab colors by kind.
    /// The mode survives hiding the panel — the panel is the legend, not the
    /// owner of the state.
    var treemapColorMode: TreemapColorMode {
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
    /// On the sunburst's Largest tab — or whenever the statistics panel is
    /// hidden, which reverts the sunburst to its default coloring — that is
    /// the Radix branch hue; every other combination keeps the treemap's
    /// kind/age semantics.
    func displayColor(for node: FileNodeRecord) -> Color {
        if vizViewMode == .sunburst, analysisTab == .largest || !showKindStats, let store {
            return SunburstColorResolver.branchColor(
                forNodeID: node.id,
                in: store,
                effectiveRootID: effectiveRootID ?? store.root.id,
                palette: vizPalette
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

    /// Volume totals are wrong without hidden system metadata
    /// (.Spotlight-V100, .fseventsd, .Trashes, …), so volume scans always
    /// include hidden files regardless of the preference.
    private func scanOptions(for target: ScanTarget) -> ScanOptions {
        var options = preferences?.scanOptions ?? ScanOptions()
        if target.kind == .volume {
            options.includeHiddenFiles = true
        }
        return options
    }

    func startScan(_ target: ScanTarget, forcesRescan: Bool = false) {
        let options = scanOptions(for: target)
        let displaysTargetAlready = coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.id == target.id
        if displaysTargetAlready {
            // Re-selecting a snapshot whose rescan the app deliberately
            // skipped must not start that rescan by accident — the notice
            // and the toolbar button are the explicit ways in.
            if !forcesRescan, snapshotNotice?.targetID == target.id {
                return
            }
            // Rescan of the location on screen: keep the map, refresh behind it.
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startRefreshScan(target, options: options)
        } else if !forcesRescan,
                  let info = cachedScanInfo[target.id],
                  shouldSkipAutoRescan(lastScanDuration: info.lastScanDuration) {
            // The policy says an unsolicited rescan would hurt (snapshot-only
            // always; smart when the last scan of this location took long):
            // display the snapshot and offer the rescan in a notice instead.
            displaySnapshotWithoutRescan(for: target, info: info)
        } else if cachedScanInfo[target.id] != nil || !hasIndexedSnapshotCache {
            // A persisted snapshot exists (or the launch index isn't ready
            // yet and one might): show it as soon as it decodes, refreshing
            // behind it. A cache miss reverts to live partial streaming
            // within milliseconds.
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startRefreshScan(target, options: options)
            restoreCachedSnapshot(for: target, canCancelRefresh: !forcesRescan)
        } else {
            snapshotNotice = nil
            resetPerScanState()
            coordinator.startScan(target, options: options)
        }
    }

    /// Whether the auto-rescan policy wants a cached snapshot displayed
    /// without an unsolicited refresh scan. Explicit rescans
    /// (forcesRescan: true) never consult this.
    private func shouldSkipAutoRescan(lastScanDuration: TimeInterval?) -> Bool {
        switch preferences?.autoRescanPolicy ?? .smart {
        case .automatic:
            return false
        case .smart:
            guard let lastScanDuration else { return false }
            return lastScanDuration > Self.autoRescanMaxLastScanDuration
        case .snapshotOnly:
            return true
        }
    }

    /// Selection, zoom, and per-snapshot UI state reset before a new scan
    /// or snapshot takes the screen.
    private func resetPerScanState() {
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
        dismissedWarningIDs = []
    }

    /// Shows the persisted snapshot of a location without rescanning it.
    /// Falls back to a live scan when the snapshot turns out unreadable.
    private func displaySnapshotWithoutRescan(for target: ScanTarget, info: CachedScanInfo) {
        snapshotNotice = nil
        resetPerScanState()
        coordinator.beginSnapshotRestore(target)
        Task { [weak self, snapshotCache] in
            let (cached, sidecar) = await Self.loadSeededSnapshot(
                for: target, in: snapshotCache, seeding: self?.kinds
            )
            guard let self else { return }
            guard self.coordinator.phase == .restoring,
                  self.coordinator.selectedTarget?.id == target.id else {
                return
            }
            if let cached {
                self.coordinator.completeSnapshotRestore(cached)
                self.syncCachedScanDate(with: cached)
                self.snapshotNotice = SnapshotNotice(
                    targetID: target.id,
                    scanDate: cached.finishedAt ?? cached.startedAt,
                    lastScanDuration: info.lastScanDuration
                )
                self.snapshotWasRestoredWithoutRescan()
                await Self.backfillKindStatsSidecarIfStale(
                    sidecar,
                    for: cached,
                    in: snapshotCache
                )
                self.kindStatsSidecarGeneration += 1
            } else {
                // Corrupt or vanished: forget the cache entry and scan live.
                self.cachedScanInfo.removeValue(forKey: target.id)
                self.coordinator.startScan(target, options: self.scanOptions(for: target))
            }
        }
    }

    /// The one way a cached snapshot is loaded for display: the kind-stats
    /// sidecar goes first (it is tiny next to the snapshot) and seeds the
    /// kind model before the decoded tree can land — the ordering that makes
    /// the first render colored instead of gray. Every restore path must
    /// come through here or it silently ships the gray-then-colored flash.
    private static func loadSeededSnapshot(
        for target: ScanTarget,
        in snapshotCache: ScanSnapshotCache,
        seeding kinds: KindStatsModel?
    ) async -> (snapshot: ScanSnapshot?, sidecar: KindStatsSidecar?) {
        let sidecar = await snapshotCache.loadAuxiliaryData(forTargetID: target.id)
            .flatMap(KindStatsSidecar.decoding)
        kinds?.prepareSeed(sidecar)
        let cached = await snapshotCache.loadSnapshot(for: target)
        return (cached, sidecar)
    }

    /// Persisted kind aggregates for a target's cached scan — the sidebar's
    /// volume bars color themselves from these without decoding the
    /// snapshot itself. nil when the target was never scanned (empty bar).
    func loadKindStatsSidecar(forTargetID targetID: String) async -> KindStatsSidecar? {
        await snapshotCache.loadAuxiliaryData(forTargetID: targetID)
            .flatMap(KindStatsSidecar.decoding)
    }

    /// Bumped whenever a kind-stats sidecar lands on disk. The sidecar is
    /// written asynchronously AFTER the snapshot save updates
    /// `cachedScanInfo` (it is an O(nodes) classification pass), so anyone
    /// reading sidecars reactively — the sidebar's volume bars — must key
    /// on this, not on the scan date, or they reload too early and miss it.
    private(set) var kindStatsSidecarGeneration = 0

    /// Snapshots cached before sidecars existed (or whose sidecar went
    /// stale) get one after display, so their next restore is seeded. Only
    /// the no-rescan endings need this — when a refresh scan keeps running,
    /// its finish writes a fresh sidecar through the save path.
    private static func backfillKindStatsSidecarIfStale(
        _ sidecar: KindStatsSidecar?,
        for cached: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        guard sidecar?.matches(cached) != true else { return }
        await saveKindStatsSidecar(for: cached, in: snapshotCache)
    }

    /// Computes and persists the kind-stats sidecar for a complete snapshot.
    /// Utility priority: this is the same O(nodes) classification pass a
    /// restore would otherwise pay at the worst moment.
    private static func saveKindStatsSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let sidecarData = await Task.detached(priority: .utility) {
            try? KindStatsSidecar.make(for: snapshot).encoded()
        }.value
        guard let sidecarData else { return }
        await snapshotCache.saveAuxiliaryData(sidecarData, forTargetID: snapshot.target.id)
    }

    /// Computes and persists the Changes-tab diff for a just-saved snapshot
    /// against its now-rotated predecessor, mirroring the kind-stats sidecar.
    /// Utility priority and off the main actor: it decodes the predecessor
    /// and runs the O(nodes) build the tab would otherwise pay on first open.
    /// A no-op when there is no predecessor to diff against.
    private static func saveChangeListSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let target = snapshot.target
        guard let previous = await snapshotCache.loadPreviousSnapshot(for: target) else { return }
        let currentStore = snapshot.treeStore
        let entryLimit = ChangesModel.entryLimit
        let list = await Task.detached(priority: .utility) {
            ScanChangeList.build(
                current: currentStore,
                previous: previous.treeStore,
                entryLimit: entryLimit
            )
        }.value
        await snapshotCache.saveChangeList(
            list,
            comparisonDate: previous.finishedAt,
            forTargetID: target.id,
            entryLimit: entryLimit
        )
    }

    /// A saved snapshot landed on screen with no refresh scan behind it, so
    /// no scan finish will run the usual conveniences — prefetch the Changes
    /// baseline and optionally start the duplicate scan here instead. (When
    /// a refresh runs behind the snapshot, its finish triggers both anyway.)
    private func snapshotWasRestoredWithoutRescan() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        diff.snapshotWasRestored(for: snapshot.target)
        // Prefer a persisted duplicate result over re-hashing: load the cached
        // run if present, and only start a fresh scan on a miss when the opt-in
        // preference is on. Relaunch never silently recomputes.
        duplicates.loadCachedResults(orScanIfMissing: preferences?.autoScanDuplicates == true)
    }

    /// The decoded snapshot is the on-disk truth. If the in-memory index
    /// disagrees (another Neodisk process wrote the cache, or the entry
    /// predates a failed save), adopt the snapshot's date so the sidebar's
    /// "Scanned … ago" matches what is actually displayed.
    private func syncCachedScanDate(with snapshot: ScanSnapshot) {
        let date = snapshot.finishedAt ?? snapshot.startedAt
        guard let info = cachedScanInfo[snapshot.target.id],
              abs(info.lastScanDate.timeIntervalSince(date)) > 1 else { return }
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: date,
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: info.hasPreviousSnapshot
        )
    }

    private func restoreCachedSnapshot(for target: ScanTarget, canCancelRefresh: Bool = false) {
        Task { [weak self, snapshotCache] in
            let (cached, sidecar) = await Self.loadSeededSnapshot(
                for: target, in: snapshotCache, seeding: self?.kinds
            )
            guard let self else { return }
            if let cached {
                self.coordinator.displayCachedSnapshot(cached)
                // The pre-index launch race can start a refresh scan before
                // anything reveals that the last scan of this location was
                // expensive. The decoded snapshot itself carries the proof —
                // when the policy would have skipped the rescan (snapshot-only
                // always; smart for a slow last scan; never under automatic),
                // stop the unsolicited scan and offer it as a notice, same
                // as the indexed path would have.
                let lastDuration = cached.finishedAt.map { $0.timeIntervalSince(cached.startedAt) }
                self.syncCachedScanDate(with: cached)
                if canCancelRefresh,
                   shouldSkipAutoRescan(lastScanDuration: lastDuration),
                   self.coordinator.isScanning,
                   self.coordinator.snapshot?.id == cached.id {
                    self.coordinator.restoreCompletedSnapshot(cached)
                    self.snapshotNotice = SnapshotNotice(
                        targetID: target.id,
                        scanDate: cached.finishedAt ?? cached.startedAt,
                        lastScanDuration: lastDuration
                    )
                    self.snapshotWasRestoredWithoutRescan()
                    // The refresh was cancelled, so no scan finish will
                    // write the sidecar this snapshot is missing.
                    await Self.backfillKindStatsSidecarIfStale(
                        sidecar,
                        for: cached,
                        in: snapshotCache
                    )
                    self.kindStatsSidecarGeneration += 1
                } else if self.coordinator.isScanning, self.coordinator.snapshot?.id == cached.id {
                    FileHandle.standardError.write(
                        Data("Neodisk: showing cached scan of \(target.id) while the refresh runs\n".utf8)
                    )
                }
            } else {
                // Corrupt or vanished: forget it and let the live scan
                // stream — unless the scan finished during the probe and
                // just recorded a fresh snapshot for this very target.
                self.coordinator.abandonCachedSnapshotDisplay(forTargetID: target.id)
                let freshlyCompleted = self.coordinator.snapshot?.isComplete == true
                    && self.coordinator.snapshot?.target.id == target.id
                if !freshlyCompleted {
                    self.cachedScanInfo.removeValue(forKey: target.id)
                }
            }
        }
    }

    private func persistCompletedSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete, snapshot.source.isPersistable else { return }
        // Saving usually rotates any existing latest snapshot into the
        // previous slot, so this target likely has a diffable previous scan
        // from now on if it had a cache entry before. Optimistic: an
        // unchanged rescan skips the rotation, and the save's outcome
        // corrects the entry (see saveSnapshotToCache).
        let hadCachedSnapshot = cachedScanInfo[snapshot.target.id] != nil
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: snapshot.finishedAt ?? Date(),
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: hadCachedSnapshot
        )
        saveSnapshotToCache(snapshot)
    }

    /// Persists the displayed snapshot after a subtree splice (rescan of a
    /// folder or expansion of a summarized one) so reopening the location
    /// keeps the refreshed data. Unlike `persistCompletedSnapshot`, the
    /// cache index keeps the last full scan's date and duration: a subtree
    /// refresh says nothing about how long a full rescan of the location
    /// takes (the duration drives the auto-rescan decision) and the
    /// sidebar's "Scanned … ago" keeps describing the full scan. Only the
    /// node count is refreshed. Saving still rotates the pre-splice
    /// snapshot into the previous slot (unless the splice changed nothing),
    /// which keeps diffing meaningful: "what changed since before this
    /// refresh".
    private func persistSplicedSnapshot() {
        guard let snapshot = coordinator.snapshot,
              snapshot.isComplete, snapshot.source.isPersistable else { return }
        let existing = cachedScanInfo[snapshot.target.id]
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: existing?.lastScanDate ?? (snapshot.finishedAt ?? Date()),
            lastScanDuration: existing?.lastScanDuration,
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: existing != nil
        )
        saveSnapshotToCache(snapshot)
    }

    private func saveSnapshotToCache(_ snapshot: ScanSnapshot) {
        Task { [weak self, snapshotCache] in
            do {
                let outcome = try await snapshotCache.save(snapshot)
                // The optimistic index entry guessed hasPreviousSnapshot
                // from "was there a cache entry"; the save knows the truth
                // (an unchanged rescan skips the rotation, so a target's
                // first rescan may leave the previous slot empty).
                self?.setHasPreviousSnapshot(
                    outcome.hasPreviousSnapshot, forTargetID: snapshot.target.id
                )
                if outcome.rotatedPrevious {
                    // Saving rotated the displayed scan's predecessor; an
                    // active diff of this target must rebase on it, and an
                    // inactive one may prefetch its baseline. A loaded Changes
                    // list compares against the replaced generation too.
                    self?.diff.snapshotWasRotated(for: snapshot.target)
                    self?.changes.snapshotWasRotated(for: snapshot.target)
                } else {
                    // Content-identical rescan: the previous slot (and any
                    // loaded baseline) still describes the right generation.
                    // Prefetch it for the fresh tree like a restore would.
                    self?.diff.snapshotWasRestored(for: snapshot.target)
                }
                // Kind stats ride along so the next restore of this
                // snapshot starts with a colored map.
                await Self.saveKindStatsSidecar(for: snapshot, in: snapshotCache)
                self?.kindStatsSidecarGeneration += 1
                // Compute and persist the change list now, off the main
                // actor, so the first open of the Changes tab is instant
                // instead of paying a predecessor decode plus O(nodes) build.
                await Self.saveChangeListSidecar(for: snapshot, in: snapshotCache)
            } catch {
                FileHandle.standardError.write(
                    Data("Neodisk: failed to persist scan snapshot: \(error)\n".utf8)
                )
            }
        }
    }

    private func bindPreferences() {
        guard let preferences else { return }
        preferencesCancellable = preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFreeSpace()
                self?.syncVizPalette()
                self?.syncVizViewMode()
                self?.syncCloudOnlyPreference()
            }
        updateFreeSpace()
        syncVizPalette()
        syncVizViewMode()
        syncCloudOnlyPreference()
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

    private func updateFreeSpace() {
        if coordinator.selectedTarget?.kind == .cloud {
            updateCloudFreeSpace()
            return
        }
        guard let target = coordinator.selectedTarget,
              target.kind == .volume else {
            freeSpaceBytes = nil
            hiddenSpaceBytes = nil
            return
        }
        freeSpaceBytes = SystemIntegration.volumeAvailableCapacityForImportantUsage(for: target.url)
        // Hidden space needs a finished scan: a partial tree would misreport
        // the not-yet-visited remainder as hidden.
        let scannedBytes: Int64?
        if let snapshot = coordinator.snapshot, snapshot.isComplete {
            scannedBytes = snapshot.treeStore.root.allocatedSize
        } else {
            scannedBytes = nil
        }
        hiddenSpaceBytes = Self.hiddenSpaceBytes(
            totalCapacity: SystemIntegration.volumeTotalCapacity(for: target.url),
            availableCapacity: freeSpaceBytes,
            scannedBytes: scannedBytes
        )
    }

    /// Free space for a cloud account: quota capacity minus the account's
    /// whole-quota usage. Renders through the same gates as volume free space
    /// (sunburst always, treemap behind the Settings toggle). There is no
    /// remote analog of purgeable/hidden space; the scan's own synthetic
    /// "Unattributed" node covers trash and versions instead.
    private func updateCloudFreeSpace() {
        guard let target = coordinator.selectedTarget, target.kind == .cloud else { return }
        hiddenSpaceBytes = nil
        freeSpaceBytes = Self.cloudFreeSpaceBytes(quota: cloudQuotaByTargetID[target.id])
        guard let cloudScan else { return }
        Task { [weak self] in
            guard let quota = await cloudScan.quota(forTargetID: target.id),
                  let self,
                  self.coordinator.selectedTarget?.id == target.id else { return }
            self.cloudQuotaByTargetID[target.id] = quota
            self.freeSpaceBytes = Self.cloudFreeSpaceBytes(quota: quota)
        }
    }

    nonisolated static func cloudFreeSpaceBytes(
        quota: (totalBytes: Int64?, usedBytes: Int64)?
    ) -> Int64? {
        // Unknown or unlimited quota → no free-space cell.
        guard let quota, let total = quota.totalBytes else { return nil }
        let free = total - quota.usedBytes
        return free > 0 ? free : nil
    }

    /// DaisyDisk-style hidden space: total capacity minus available capacity
    /// minus what the scan accounted for, clamped at zero (nil when any input
    /// is missing or nothing remains). Uses the same available-capacity figure
    /// as the free-space cell, so scanned + free + hidden tiles the volume
    /// exactly instead of double-counting purgeable space.
    nonisolated static func hiddenSpaceBytes(
        totalCapacity: Int64?,
        availableCapacity: Int64?,
        scannedBytes: Int64?
    ) -> Int64? {
        guard let totalCapacity, let availableCapacity, let scannedBytes else { return nil }
        let hidden = totalCapacity - availableCapacity - scannedBytes
        return hidden > 0 ? hidden : nil
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
            cachedScanInfo.removeValue(forKey: id)
        }
        Task { [snapshotCache] in
            for id in removedIDs {
                await snapshotCache.removeSnapshot(forTargetID: id)
            }
        }
    }

    /// The previous snapshot of a target turned out to be unreadable or
    /// gone; reflect that in the cache index so the diff toggle disables.
    func markPreviousSnapshotMissing(forTargetID targetID: String) {
        setHasPreviousSnapshot(false, forTargetID: targetID)
    }

    private func setHasPreviousSnapshot(_ hasPrevious: Bool, forTargetID targetID: String) {
        guard let info = cachedScanInfo[targetID],
              info.hasPreviousSnapshot != hasPrevious else { return }
        cachedScanInfo[targetID] = CachedScanInfo(
            lastScanDate: info.lastScanDate,
            lastScanDuration: info.lastScanDuration,
            nodeCount: info.nodeCount,
            hasPreviousSnapshot: hasPrevious
        )
    }

    // MARK: - Cloud accounts

    /// Re-reads the connected cloud accounts after a connect or sign-out. The
    /// assignment fires observation, so the sidebar's Cloud Drives section
    /// updates.
    private func refreshCloudDriveAccounts() {
        cloudDriveAccounts = cloudScan?.accountTargets ?? []
    }

    /// Runs the provider's OAuth flow (opening the browser) and, on success,
    /// scans the new account. Failures surface through the standard action
    /// alert.
    func connectCloudAccount(providerID: String) {
        guard let cloudScan else { return }
        Task { [weak self] in
            do {
                let target = try await cloudScan.connectAccount(providerID: providerID)
                self?.startScan(target)
            } catch {
                self?.actionErrorMessage = error.localizedDescription
            }
        }
    }

    /// Signs out of a connected cloud account: revokes and forgets its
    /// credentials, drops its cached scan, and clears the display if that
    /// account is what's on screen.
    func signOutCloudAccount(targetID: String) {
        guard let cloudScan else { return }
        let wasDisplayed = coordinator.selectedTarget?.id == targetID
        Task { [weak self, snapshotCache] in
            await cloudScan.signOut(targetID: targetID)
            await snapshotCache.removeSnapshot(forTargetID: targetID)
            guard let self else { return }
            self.cachedScanInfo.removeValue(forKey: targetID)
            if wasDisplayed {
                self.coordinator.clearScan()
            }
        }
    }

    // MARK: - Snapshot cache maintenance

    /// Total disk usage of persisted snapshots, for Settings → Privacy.
    func scanSnapshotCacheSize() async -> Int64 {
        await snapshotCache.totalSizeOnDisk()
    }

    func clearScanSnapshots() async {
        await snapshotCache.removeAll()
        cachedScanInfo = [:]
    }

    private func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        updateFreeSpace()

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

    // MARK: - Selection & zoom

    func select(_ nodeID: String?) {
        selectedNodeID = nodeID  // its didSet widens the map if the node is off-screen
        if let nodeID {
            revealInOutline(nodeID)
            // With duplicate results on screen, selecting a copy anywhere
            // (treemap, outline) drills into its group; selecting a
            // non-duplicate steps back out of an open group.
            if analysisTab == .duplicates {
                duplicates.handleSelection(of: nodeID)
            }
        }
    }

    /// Keeps a selection visible when the map is drilled in: if the node lands
    /// outside the current root, widen the root OUT to the lowest common
    /// ancestor of the current root and the node. Only ever drills out —
    /// selecting something on the far side of the tree never narrows the view
    /// (drilling in stays ⌘↓). No-op at the full map, or when the node is
    /// already inside the drilled subtree.
    private func widenRootToShow(_ nodeID: String) {
        guard let store, let currentRootID = effectiveRootID,
              currentRootID != store.root.id,
              !store.isAncestor(currentRootID, of: nodeID) else { return }
        // Both paths start at the scan root; the last shared node is the LCA.
        var lca = store.root.id
        for (a, b) in zip(store.path(to: currentRootID), store.path(to: nodeID)) {
            if a.id != b.id { break }
            lca = a.id
        }
        zoomRootID = lca == store.root.id ? nil : lca
    }

    /// Expands every ancestor so the outline shows the selected row.
    func revealInOutline(_ nodeID: String) {
        guard let store else { return }
        for ancestor in store.path(to: nodeID).dropLast() {
            expandedNodeIDs.insert(ancestor.id)
        }
    }

    func zoomOut() {
        guard let store, let effectiveRootID,
              let parent = store.parent(of: effectiveRootID) else {
            zoomRootID = nil
            return
        }
        zoomRootID = parent.id == store.root.id ? nil : parent.id
    }

    /// Keyboard drill-in (⌘↓): re-root the treemap into the selected folder,
    /// or into the folder containing the selected file, so "zoom into where I
    /// am" always makes progress. Returns false (caller beeps) when there is
    /// nowhere deeper to go — no selection, or already rooted at the target.
    @discardableResult
    func drillIntoSelection() -> Bool {
        guard let store, let node = selectedNode else { return false }
        // A selected directory is drilled into; a selected file drills into
        // its containing folder.
        let targetDir = node.isDirectory ? node : store.parent(of: node.id)
        guard let dir = targetDir, dir.isDirectory, dir.id != effectiveRootID else {
            return false
        }
        // A summarized folder has no children in the store yet: expand its
        // real contents (async scan + splice) instead of drilling into a blank
        // subtree. It populates in place; a second ⌘↓ then drills in normally.
        if dir.isAutoSummarized {
            guard canRefreshSubtree else { return false }
            expandNodeContents(dir)
            return true
        }
        // Other childless folders (empty dirs, opaque packages) have nothing
        // to render — don't re-root into a blank map.
        guard store.children(of: dir.id).contains(where: { $0.allocatedSize > 0 }) else {
            return false
        }
        zoomRootID = dir.id == store.root.id ? nil : dir.id
        // When the user explicitly drilled into a folder, land the selection
        // on its largest child so arrow keys keep working inside.
        if node.isDirectory {
            let children = store.children(of: dir.id).filter { $0.allocatedSize > 0 }
            if let largest = children.max(by: { $0.allocatedSize < $1.allocatedSize }) {
                select(largest.id)
            }
        }
        return true
    }

    /// Breadcrumb navigation: re-root the treemap OUT to an ancestor folder.
    /// Only drills out — the target must be strictly above the current map
    /// root; drilling in stays keyboard-only (⌘↓). The selection is left
    /// untouched (it stays a descendant of the wider root). Returns false when
    /// the crumb isn't an out target, so the caller can fall back to selecting.
    @discardableResult
    func reRoot(to nodeID: String) -> Bool {
        guard let store, let node = store.node(id: nodeID), node.isDirectory,
              let effectiveRootID, node.id != effectiveRootID,
              store.isAncestor(node.id, of: effectiveRootID) else { return false }
        zoomRootID = node.id == store.root.id ? nil : node.id
        return true
    }

    /// Breadcrumb navigation: re-root the treemap IN to a descendant folder —
    /// the symmetric partner of `reRoot`. The target must sit strictly below
    /// the current map root (a crumb between the root and the selection). The
    /// selection is preserved when it stays inside the new root; otherwise it
    /// lands on the folder's largest child, matching ⌘↓. Returns false when the
    /// crumb isn't an in target, so the caller can fall back to selecting.
    @discardableResult
    func drillIn(to nodeID: String) -> Bool {
        guard let store, let node = store.node(id: nodeID), node.isDirectory,
              let effectiveRootID, node.id != effectiveRootID,
              store.isAncestor(effectiveRootID, of: node.id) else { return false }
        // A summarized folder has no children in the store yet: expand its real
        // contents instead of re-rooting into a blank subtree (mirrors ⌘↓).
        if node.isAutoSummarized {
            guard canRefreshSubtree else { return false }
            expandNodeContents(node)
            return true
        }
        // Childless folders (empty dirs, opaque packages) have nothing to render.
        guard store.children(of: node.id).contains(where: { $0.allocatedSize > 0 }) else {
            return false
        }
        zoomRootID = node.id == store.root.id ? nil : node.id
        // Keep the selection if it stays a descendant of the new root; otherwise
        // (the crumb was the selection itself, or nothing is selected) land on
        // the largest child so the outline and arrow keys stay oriented.
        let selectionStaysInside = selectedNodeID.map {
            $0 != node.id && store.isAncestor(node.id, of: $0)
        } ?? false
        if !selectionStaysInside {
            let children = store.children(of: node.id).filter { $0.allocatedSize > 0 }
            if let largest = children.max(by: { $0.allocatedSize < $1.allocatedSize }) {
                select(largest.id)
            }
        }
        return true
    }

    /// Keyboard drill-out (⌘↑): re-root the treemap one level up. Returns
    /// false (caller beeps) when already at the scan root.
    @discardableResult
    func drillOut() -> Bool {
        guard let store, let effectiveRootID, effectiveRootID != store.root.id else {
            return false
        }
        zoomOut()
        return true
    }

    // MARK: - File actions

    /// False for a cloud snapshot: its nodes' paths are `cloudscan://`
    /// identifiers, not filesystem paths, so Reveal in Finder / Open / Copy
    /// Path / double-click reveal have nothing on disk to act on.
    var snapshotSupportsFileActions: Bool {
        coordinator.snapshot?.target.kind != .cloud
    }

    /// Whether the node's file actions (Reveal in Finder / Open / Copy Path)
    /// apply: the node must offer them and the displayed snapshot must be a
    /// filesystem scan.
    func supportsFileActions(_ node: FileNodeRecord) -> Bool {
        node.supportsFileActions && snapshotSupportsFileActions
    }

    /// Spacebar Quick Look shared by the treemap and sunburst: previews the
    /// selected node, so click-then-space works without ever focusing one of
    /// the sidebar lists. Beeps when nothing is selected.
    func quickLookSelection() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        QuickLookPresenter.shared.togglePreview(for: node)
    }

    /// Return-key reveal shared by the treemap and sunburst. Beeps when the
    /// selection has no on-disk counterpart to show.
    func revealSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        reveal(node)
    }

    func reveal(_ node: FileNodeRecord) {
        SystemIntegration.reveal(node.url)
    }

    func open(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.open(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func copyPath(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.copyPath(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
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
        var options = coordinator.snapshot.map { scanOptions(for: $0.target) }
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
            persistSplicedSnapshot()
        case .failed(let message):
            actionErrorMessage = message
        case .skipped, .cancelled:
            break
        }
    }

    // MARK: - Outline rows

    struct OutlineRow: Identifiable {
        let node: FileNodeRecord
        let depth: Int
        let isExpandable: Bool

        var id: String { node.id }
    }

    /// Depth-first flattening of the expanded portion of the tree. In diff
    /// mode, siblings order by how much they changed since the baseline
    /// (largest magnitude first, growth or shrinkage alike) instead of the
    /// store's size order — everything that moved reads top-down.
    func visibleOutlineRows() -> [OutlineRow] {
        guard let store, let effectiveRootID,
              let root = store.node(id: effectiveRootID) else { return [] }

        var rows: [OutlineRow] = []
        var stack: [(node: FileNodeRecord, depth: Int)] = [(root, 0)]

        while let (node, depth) = stack.popLast() {
            let isExpandable = node.isDirectory && store.containsChildren(id: node.id)
            rows.append(OutlineRow(node: node, depth: depth, isExpandable: isExpandable))

            if isExpandable, expandedNodeIDs.contains(node.id) {
                var children = store.children(of: node.id)
                if let baseline = diff.baseline {
                    children.sort {
                        baseline.sizeDelta(for: $0).magnitude > baseline.sizeDelta(for: $1).magnitude
                    }
                }
                for child in children.reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return rows
    }

    func toggleExpansion(_ nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
    }
}
