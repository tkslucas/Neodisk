//
//  AppModel.swift
//  NeodiskGTK
//
//  The Linux shell's central state: what is scanned and on screen, the scan
//  lifecycle around the snapshot cache, selection, focus, and the kind/age
//  catalogs that color the map. The GTK views observe it (see
//  Observation.swift); the heavy lifting — scanning, snapshot codecs,
//  catalogs, scene building — is the shared core's.
//

import Foundation
import NeodiskAppModel
import NeodiskKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        /// A live scan streams to the screen (partial trees, then final).
        case scanning
        /// A cached snapshot is decoding for display.
        case restoring
        case displaying
        case failed(String)
    }

    let preferences: Preferences
    @ObservationIgnored let snapshotCache: ScanSnapshotCache

    private(set) var phase: Phase = .idle
    private(set) var target: ScanTarget?
    /// The tree the views draw: a partial store while a scan streams, then
    /// the finished snapshot's.
    private(set) var store: FileTreeStore? {
        didSet { storeGeneration &+= 1 }
    }
    /// Bumps with every tree swap, so work started against one tree can
    /// tell it was superseded.
    @ObservationIgnored private(set) var storeGeneration = 0
    /// The complete snapshot on screen, when there is one.
    private(set) var snapshot: ScanSnapshot?
    /// Live progress of the running scan.
    private(set) var metrics = ScanMetrics()
    /// True while a rescan runs behind a displayed complete snapshot: the
    /// map keeps the old tree (a complete stale map beats an incomplete
    /// fresh one) until the new one finishes.
    private(set) var isRefreshing = false
    private(set) var warnings: [ScanWarning] = []
    private(set) var volumeSpace: VolumeSpaceInfo?
    private(set) var catalog: FileKindCatalog = .empty
    private(set) var ageCatalog: AgeCatalog = .empty
    /// What the snapshot cache holds per target path (sidebar subtitles).
    private(set) var cachedScans: [String: CachedScanInfo] = [:]
    /// Bumps whenever a kind-stats sidecar lands on disk. The sidecar is
    /// written after the snapshot save updates `cachedScans` (it's an
    /// O(nodes) classification pass), so the sidebar's capacity bars key
    /// on this, not on the scan date, or they'd reload before it exists.
    private(set) var kindStatsSidecarGeneration = 0
    /// Ticks once a minute, so "Scanned 5 minutes ago" labels that read it
    /// stay current.
    private(set) var minuteTick = 0
    /// The whole-scan name index behind search: one per displayed snapshot,
    /// built in the background as soon as the snapshot lands, as the Mac's
    /// Largest panel does, so the first search doesn't wait on it.
    @ObservationIgnored let searchIndex = SearchIndexService()
    @ObservationIgnored private var minuteTimer: Task<Void, Never>?

    /// The statistics tab on screen; it decides what map color means.
    var analysisTab: AnalysisTab = .largest
    /// The Kinds tab's drill-in: that kind stays lit, the rest dims.
    var highlightedKindID: String?
    /// The Age tab's drill-in bucket.
    var highlightedAgeBucket: AgeBucket?

    var selectedNodeID: String?
    var hoveredNodeID: String?
    /// The folder the visualizations are drilled into; nil is the root.
    var focusID: String?
    /// Folders whose "smaller items" cell was clicked open.
    var expandedAggregateIDs: Set<String> = []

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var kindCatalogTask: Task<Void, Never>?
    @ObservationIgnored private var ageCatalogTask: Task<Void, Never>?
    @ObservationIgnored private var catalogThrottle = CatalogRebuildThrottle()
    /// Kind catalogs built for the tree on screen, by grouping mode, so
    /// switching back to Categories or Types is instant.
    @ObservationIgnored private var kindCatalogCache: [FileKindDisplayMode: FileKindCatalog] = [:]
    /// Persisted kind stats loaded ahead of a snapshot restore, waiting for
    /// the decoded snapshot to prove they describe it.
    @ObservationIgnored private var pendingSeed: KindStatsSidecar?
    /// Persisted kind stats proven to match the tree on screen: kind catalog
    /// builds (restore, grouping mode, palette) skip the O(nodes) pass.
    @ObservationIgnored private var activeSeed: KindStatsSidecar?
    @ObservationIgnored private var scanStartedAt: Date?

    init(preferences: Preferences, snapshotCache: ScanSnapshotCache = ScanSnapshotCache()) {
        self.preferences = preferences
        self.snapshotCache = snapshotCache
        minuteTimer = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(60))) != nil {
                self?.minuteTick &+= 1
            }
        }
    }

    /// True after Stop cut a scan short with no complete snapshot to fall
    /// back on: the map shows what was read so far.
    var isShowingPartialScan: Bool {
        phase == .displaying && snapshot == nil && store != nil
    }

    // MARK: - Derived

    /// Without a kind or age legend on screen (the Largest tab, or the
    /// panel hidden) the map shows the structural branch hues, as on the Mac.
    var showsBranchColors: Bool {
        analysisTab == .largest || !preferences.showsStatistics
    }

    var colorMode: TreemapColorMode {
        if showsBranchColors { return .branch }
        guard analysisTab == .age else { return .kind }
        let referenceDate = ageCatalog.stats.isEmpty
            ? snapshot.map { $0.finishedAt ?? $0.startedAt }
            : ageCatalog.referenceDate
        return referenceDate.map { .age(referenceDate: $0) } ?? .kind
    }

    /// The visible tab's drill-in highlight, if any.
    var highlight: TreemapHighlight? {
        guard !showsBranchColors else { return nil }
        switch analysisTab {
        case .kinds: return highlightedKindID.map { .kind($0) }
        case .age: return highlightedAgeBucket.map { .ageBucket($0) }
        case .largest: return nil
        }
    }

    var isScanning: Bool { phase == .scanning || isRefreshing }
    var rootID: String? { store?.rootID }
    var focusedRootID: String? { focusID ?? store?.rootID }
    var selectedNode: FileNodeRecord? { store?.node(id: selectedNodeID) }
    var hoveredNode: FileNodeRecord? { store?.node(id: hoveredNodeID) }
    var palette: VizPalette { preferences.palette }

    /// Used capacity the scan could not account for (other users' files,
    /// unreadable paths, filesystem metadata), for volume scans.
    var hiddenSpaceBytes: Int64? {
        guard let volumeSpace, let store, target?.kind == .volume else { return nil }
        return volumeSpace.hiddenSpaceBytes(scannedBytes: store.root.allocatedSize)
    }

    // MARK: - Opening and scanning

    /// Shows `target`: from the snapshot cache when it holds one (instant,
    /// and the user decides when to rescan), otherwise by scanning it.
    func open(_ target: ScanTarget) {
        cancelScan()
        self.target = target
        resetPerTargetState()
        if target.kind == .folder {
            preferences.noteRecentFolder(target.id)
        }
        phase = .restoring
        scanTask = Task { [weak self] in
            guard let self else { return }
            // The sidecar is tiny next to the snapshot: read it first, so the
            // restored map is colored as soon as it's on screen.
            pendingSeed = await loadKindStatsSidecar(forTargetID: target.id)
            if let cached = await snapshotCache.loadSnapshot(for: target), !Task.isCancelled {
                display(cached)
                await backfillKindStatsSidecarIfStale(for: cached)
                return
            }
            guard !Task.isCancelled else { return }
            await runScan(target, behindDisplayedSnapshot: false)
        }
    }

    /// Scans the current target again. A displayed complete snapshot stays
    /// on screen until the fresh one lands.
    func rescan() {
        guard let target else { return }
        cancelScan()
        let keepsDisplayedTree = snapshot != nil
        scanTask = Task { [weak self] in
            await self?.runScan(target, behindDisplayedSnapshot: keepsDisplayedTree)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if isRefreshing {
            isRefreshing = false
        } else if phase == .scanning || phase == .restoring {
            phase = store == nil ? .idle : .displaying
        }
    }

    private func resetPerTargetState() {
        store = nil
        snapshot = nil
        warnings = []
        metrics = ScanMetrics()
        selectedNodeID = nil
        hoveredNodeID = nil
        focusID = nil
        expandedAggregateIDs = []
        catalog = .empty
        ageCatalog = .empty
        kindCatalogCache = [:]
        pendingSeed = nil
        activeSeed = nil
        // Frees the previous location's index instead of holding two trees.
        searchIndex.invalidate()
        catalogThrottle.reset()
        isRefreshing = false
        volumeSpace = target.flatMap { $0.kind == .volume ? VolumeSpaceInfo.load(for: $0.url) : nil }
    }

    private func runScan(_ target: ScanTarget, behindDisplayedSnapshot: Bool) async {
        metrics = ScanMetrics()
        warnings = []
        scanStartedAt = Date()
        if behindDisplayedSnapshot {
            isRefreshing = true
        } else {
            phase = .scanning
        }
        if target.kind == .volume {
            volumeSpace = VolumeSpaceInfo.load(for: target.url)
        }

        let service = IncrementalScanService()
        let baseline = snapshot
        let stream = baseline == nil
            ? service.scan(target: target, options: preferences.scanOptions)
            : service.rescan(target: target, options: preferences.scanOptions, baselineProvider: { baseline })
        do {
            for try await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .progress(let progress):
                    metrics = progress
                case .warning(let warning):
                    warnings.append(warning)
                case .partial(let partialStore):
                    guard !behindDisplayedSnapshot else { continue }
                    store = partialStore
                    rebuildCatalogs(for: partialStore, referenceDate: Date(), isPartial: true)
                case .finished(let finished):
                    var progress = metrics
                    progress.progressFraction = 1
                    metrics = progress
                    display(finished)
                    await persist(finished)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            isRefreshing = false
            phase = store == nil ? .failed(error.localizedDescription) : .displaying
        }
    }

    private func display(_ snapshot: ScanSnapshot) {
        let previousSelection = selectedNodeID
        let previousFocus = focusID
        self.snapshot = snapshot
        Task { [searchIndex] in _ = await searchIndex.index(for: snapshot) }
        store = snapshot.treeStore
        warnings = snapshot.scanWarnings
        isRefreshing = false
        phase = .displaying
        // A refresh keeps the user's place when it still exists.
        selectedNodeID = snapshot.treeStore.node(id: previousSelection) == nil ? nil : previousSelection
        focusID = snapshot.treeStore.node(id: previousFocus) == nil ? nil : previousFocus
        if snapshot.target.kind == .volume {
            volumeSpace = VolumeSpaceInfo.load(for: snapshot.target.url)
        }
        // Pending stats either prove they describe this snapshot or die
        // here; stats matched to a previous tree stop being used.
        if let pendingSeed, pendingSeed.matches(snapshot) {
            activeSeed = pendingSeed
        } else if let activeSeed, !activeSeed.matches(snapshot) {
            self.activeSeed = nil
        }
        pendingSeed = nil
        rebuildCatalogs(
            for: snapshot.treeStore,
            referenceDate: snapshot.finishedAt ?? snapshot.startedAt,
            isPartial: false
        )
    }

    private func persist(_ snapshot: ScanSnapshot) async {
        do {
            try await snapshotCache.save(snapshot)
        } catch {
            FileHandle.standardError.write(Data("neodisk: could not cache the scan: \(error)\n".utf8))
        }
        await refreshCachedScans()
        await saveKindStatsSidecar(for: snapshot)
    }

    /// Persisted kind aggregates for a target's cached scan: the sidebar's
    /// capacity bars color themselves from these without decoding the
    /// snapshot. nil when the target was never scanned.
    func loadKindStatsSidecar(forTargetID targetID: String) async -> KindStatsSidecar? {
        await snapshotCache.loadAuxiliaryData(forTargetID: targetID)
            .flatMap(KindStatsSidecar.decoding)
    }

    /// Computes and persists the kind-stats sidecar for a complete snapshot,
    /// at utility priority (the same O(nodes) pass as a catalog build).
    private func saveKindStatsSidecar(for snapshot: ScanSnapshot) async {
        let sidecar = await Task.detached(priority: .utility) {
            KindStatsSidecar.make(for: snapshot)
        }.value
        // From now on, grouping and palette switches on this tree are instant.
        if self.snapshot?.id == snapshot.id {
            activeSeed = sidecar
        }
        guard let data = try? sidecar.encoded() else { return }
        await snapshotCache.saveAuxiliaryData(data, forTargetID: snapshot.target.id)
        kindStatsSidecarGeneration &+= 1
    }

    /// Snapshots cached before sidecars existed (or whose sidecar went
    /// stale) get one after they're shown.
    private func backfillKindStatsSidecarIfStale(for snapshot: ScanSnapshot) async {
        let existing = await loadKindStatsSidecar(forTargetID: snapshot.target.id)
        guard existing?.matches(snapshot) != true else { return }
        await saveKindStatsSidecar(for: snapshot)
    }

    /// Re-indexes the snapshot cache, keeping only snapshots of locations
    /// the app still offers (volumes, home, recent folders).
    func refreshCachedScans(keeping locations: Set<String>? = nil) async {
        var keep = locations ?? Set(cachedScans.keys)
        keep.formUnion(preferences.recentFolders)
        if let target { keep.insert(target.id) }
        cachedScans = await snapshotCache.pruneAndIndex(keepingTargetIDs: keep)
    }

    // MARK: - Catalogs

    /// Rebuilds the kind and age catalogs off the main actor. Partial trees
    /// rebuild on a throttle that backs off with the measured build cost.
    func rebuildCatalogs(for store: FileTreeStore, referenceDate: Date, isPartial: Bool) {
        if isPartial, catalogThrottle.shouldSkip() { return }
        catalogThrottle.noteBuildStarted()
        kindCatalogCache = [:]
        if isPartial {
            activeSeed = nil
        }
        rebuildKindCatalog(for: store)
        let generation = storeGeneration
        ageCatalogTask?.cancel()
        ageCatalogTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                AgeCatalog.build(from: store, referenceDate: referenceDate)
            }.cancellableValue
            guard let self, !Task.isCancelled, self.storeGeneration == generation else { return }
            self.ageCatalog = built
        }
    }

    /// The kind catalog for the current grouping mode: from the cache, from
    /// matching persisted stats (milliseconds), or from a full pass.
    private func rebuildKindCatalog(for store: FileTreeStore) {
        let mode = preferences.kindMode
        if let cached = kindCatalogCache[mode] {
            kindCatalogTask?.cancel()
            catalog = cached
            return
        }
        let palette = preferences.palette
        let seedStats = activeSeed?.stats(for: mode)
        let generation = storeGeneration
        kindCatalogTask?.cancel()
        kindCatalogTask = Task { [weak self] in
            let started = ContinuousClock.now
            let built = await Task.detached(priority: .userInitiated) {
                if let seedStats {
                    return FileKindCatalog.build(fromAggregated: seedStats, mode: mode, palette: palette)
                }
                return FileKindCatalog.build(from: store, mode: mode, palette: palette)
            }.cancellableValue
            guard let self, !Task.isCancelled, self.storeGeneration == generation else { return }
            self.catalogThrottle.noteBuildDuration(ContinuousClock.now - started)
            self.kindCatalogCache[mode] = built
            // A mode switched again while this built: show only the current one.
            if self.preferences.kindMode == mode {
                self.catalog = built
            }
        }
    }

    /// Categories or Types picked: recolor from the current tree.
    func kindModeDidChange() {
        guard let store else { return }
        rebuildKindCatalog(for: store)
    }

    /// Palette changed: colors are baked into kind catalogs at build time.
    func paletteDidChange() {
        guard let store else { return }
        kindCatalogCache = [:]
        rebuildKindCatalog(for: store)
    }

    // MARK: - Selection and focus

    func select(_ nodeID: String?) {
        guard selectedNodeID != nodeID else { return }
        selectedNodeID = nodeID
        // A selection outside the drilled-in folder widens the focus to show
        // it, as on the Mac.
        if let nodeID, let store, let focusID, !store.isAncestor(focusID, of: nodeID), focusID != nodeID {
            self.focusID = store.parent(of: nodeID)?.id
        }
    }

    /// Re-roots the visualizations at `nodeID` (a folder on the path above
    /// the current focus, or the root) — the breadcrumb's action.
    func focus(on nodeID: String?) {
        guard let store else { return }
        guard let nodeID, nodeID != store.rootID else {
            focusID = nil
            return
        }
        guard let node = store.node(id: nodeID), node.isDirectory, store.containsChildren(id: nodeID) else { return }
        focusID = nodeID
    }

    /// Drills into a folder: `nodeID` itself, or the folder containing it
    /// when it's a file — the Mac's ⌘↓, so "zoom into where I am" always
    /// makes progress. An explicitly drilled folder lands the selection on
    /// its largest child, keeping the arrow keys and the outline oriented.
    /// Returns false (caller beeps) when there is nowhere deeper to go.
    @discardableResult
    func drillIn(to nodeID: String?) -> Bool {
        guard let store, let nodeID, let node = store.node(id: nodeID) else { return false }
        guard let folder = node.isDirectory ? node : store.parent(of: node.id),
              folder.isDirectory, folder.id != focusedRootID else { return false }
        // Summarized folders, empty ones, and opaque packages have nothing
        // to draw once rooted there.
        let children = store.children(of: folder.id).filter { $0.allocatedSize > 0 }
        guard !children.isEmpty else { return false }
        focusID = folder.id == store.rootID ? nil : folder.id
        if node.isDirectory, let largest = children.max(by: { $0.allocatedSize < $1.allocatedSize }) {
            selectedNodeID = largest.id
        }
        return true
    }

    @discardableResult
    func drillIntoSelection() -> Bool {
        drillIn(to: selectedNodeID)
    }

    /// Drills out one level.
    func focusOut() {
        guard let store, let focusID else { return }
        let parent = store.parent(of: focusID)?.id
        self.focusID = parent == store.rootID ? nil : parent
        selectedNodeID = focusID
    }

    var canFocusOut: Bool { focusID != nil }
}

enum AnalysisTab: String, CaseIterable {
    case largest
    case kinds
    case age

    var title: String {
        switch self {
        case .largest: return L("Largest")
        case .kinds: return L("Kinds")
        case .age: return L("Age")
        }
    }
}
