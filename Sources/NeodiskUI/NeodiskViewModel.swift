//
//  NeodiskViewModel.swift
//  Neodisk
//
//  Central UI state: scan lifecycle, selection, zoom, kind statistics, and
//  the rendered treemap.
//

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
    /// Node the treemap is currently zoomed into; nil means the snapshot root.
    var zoomRootID: String?
    /// Folders whose "smaller items" cell the user clicked open — their
    /// children render individually even when tiny.
    var expandedAggregateIDs: Set<String> = []
    var showKindStats = true
    /// Locations sidebar visibility; lives here so the View menu can toggle
    /// it. Always starts visible.
    var sidebarVisibility = NavigationSplitViewVisibility.all

    // MARK: Kind statistics

    /// Kind catalog, display mode, and drill-in file list; see
    /// KindStatsModel.
    let kinds: KindStatsModel

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

    /// Scan warnings still visible in the floating panel (capped to keep the
    /// panel responsive on scans with thousands of skipped items).
    var visibleScanWarnings: [ScanWarning] {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return [] }
        // Eager loop: a lazy filter whose predicate mutates state (the seen-ID
        // dedupe) violates Collection semantics and traps inside prefix(_:).
        var seenIDs = Set<ScanWarning.ID>()
        var visible: [ScanWarning] = []
        for warning in snapshot.scanWarnings {
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
    /// User-added sidebar folders, persisted across launches.
    var pinnedFolders: [ScanTarget] = []
    /// Volumes and standard folders shown in the sidebar.
    let smartLocations = SystemIntegration.defaultTargets()
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

    /// "Changes since last scan" baseline and toggle; see DiffModel.
    let diff: DiffModel
    /// Free space of the scanned volume, when the preference is on and the
    /// scan target is a volume; drawn as a synthetic treemap cell.
    var freeSpaceBytes: Int64?

    /// Settings backing scan options and the free-space cell; assigned once
    /// by the app at launch.
    var preferences: AppPreferences? {
        didSet { bindPreferences() }
    }

    /// One search index per displayed snapshot, shared by the outline
    /// search and the kind drill-in list.
    @ObservationIgnored private let searchIndexService = SearchIndexService()
    @ObservationIgnored private let pinnedFolderStore: PinnedFolderStore
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// False until the launch prune has filled `cachedScanInfo`; before that,
    /// scans probe the cache optimistically instead of trusting the index.
    @ObservationIgnored private var hasIndexedSnapshotCache = false
    @ObservationIgnored private var preferencesCancellable: AnyCancellable?

    init(
        coordinator: ScanCoordinator = ScanCoordinator(),
        snapshotCache: ScanSnapshotCache = ScanSnapshotCache(),
        pinnedFolderStore: PinnedFolderStore = PinnedFolderStore()
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.pinnedFolderStore = pinnedFolderStore
        self.search = SearchModel(coordinator: coordinator, indexService: searchIndexService)
        self.kinds = KindStatsModel(coordinator: coordinator, indexService: searchIndexService)
        self.diff = DiffModel(coordinator: coordinator, snapshotCache: snapshotCache)
        pinnedFolders = pinnedFolderStore.load()
        diff.model = self

        // The coordinator is @Observable, so views track its properties
        // (phase, snapshot, …) directly; the model only needs the snapshot
        // change hook for its own bookkeeping.
        coordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshotDidChange(snapshot)
        }

        coordinator.onScanFinished = { [weak self] snapshot in
            self?.persistCompletedSnapshot(snapshot)
        }

        // Drop cache entries for locations no longer in the sidebar and
        // learn which targets can open instantly from cache.
        let validTargetIDs = Set((smartLocations + pinnedFolders).map(\.id))
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
            let cached = await snapshotCache.loadSnapshot(for: target)
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
            } else {
                // Corrupt or vanished: forget the cache entry and scan live.
                self.cachedScanInfo.removeValue(forKey: target.id)
                self.coordinator.startScan(target, options: self.scanOptions(for: target))
            }
        }
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
            let cached = await snapshotCache.loadSnapshot(for: target)
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
        // Saving rotates any existing latest snapshot into the previous
        // slot, so this target has a diffable previous scan from now on if
        // it had a cache entry before.
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
    /// snapshot into the previous slot, which keeps diffing meaningful:
    /// "what changed since before this refresh".
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
                try await snapshotCache.save(snapshot)
                // Saving rotated the displayed scan's predecessor; an
                // active diff of this target must rebase on it.
                self?.diff.rebaseAfterSnapshotRotation(for: snapshot.target)
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
            }
        updateFreeSpace()
    }

    private func updateFreeSpace() {
        guard preferences?.showFreeSpace == true,
              let target = coordinator.selectedTarget,
              target.kind == .volume else {
            freeSpaceBytes = nil
            return
        }
        freeSpaceBytes = SystemIntegration.volumeAvailableCapacityForImportantUsage(for: target.url)
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
    /// Smart locations never get pinned — they are already in the sidebar.
    func chooseFolderAndScan() {
        guard let target = SystemIntegration.presentScanPanel() else { return }
        let isSmartLocation = smartLocations.contains { $0.id == target.id }
        if !isSmartLocation, !pinnedFolders.contains(where: { $0.id == target.id }) {
            pinnedFolders.append(target)
            pinnedFolderStore.add(target)
        }
        startScan(target)
    }

    /// Handles folders dropped onto the window or the sidebar: pins each
    /// one (same rules as Add Folder… — smart locations and duplicates
    /// stay unpinned) and starts scanning the first. Non-folder drops are
    /// ignored.
    @discardableResult
    func addDroppedFolders(_ urls: [URL]) -> Bool {
        let folderURLs = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folderURLs.isEmpty else { return false }

        let smartIDs = Set(smartLocations.map(\.id))
        var firstTarget: ScanTarget?
        for url in folderURLs {
            let target = ScanTarget(url: url)
            if firstTarget == nil { firstTarget = target }
            if !smartIDs.contains(target.id),
               !pinnedFolders.contains(where: { $0.id == target.id }) {
                pinnedFolders.append(target)
                pinnedFolderStore.add(target)
            }
        }
        if let firstTarget {
            startScan(firstTarget)
        }
        return true
    }

    func removePinnedFolders(ids: Set<String>) {
        for target in pinnedFolders where ids.contains(target.id) {
            pinnedFolderStore.remove(target)
        }
        pinnedFolders.removeAll { ids.contains($0.id) }

        // A removed folder loses its persisted snapshot too — unless it is
        // also a smart location, which keeps its own cache entry.
        let removedIDs = ids.subtracting(smartLocations.map(\.id))
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
        guard let info = cachedScanInfo[targetID] else { return }
        cachedScanInfo[targetID] = CachedScanInfo(
            lastScanDate: info.lastScanDate,
            lastScanDuration: info.lastScanDuration,
            nodeCount: info.nodeCount,
            hasPreviousSnapshot: false
        )
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

        // The kind catalog, the drilled-in kind list, and the shared
        // search index are all keyed to the replaced tree.
        searchIndexService.invalidate()
        kinds.snapshotDidChange(snapshot)
        search.snapshotDidChange()

        guard let snapshot else { return }

        // Expand the root row by default so the outline isn't a single line.
        expandedNodeIDs.insert(snapshot.treeStore.root.id)
    }

    // MARK: - Selection & zoom

    func select(_ nodeID: String?) {
        selectedNodeID = nodeID
        if let nodeID {
            revealInOutline(nodeID)
        }
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

    // MARK: - File actions

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

    /// Scans an auto-summarized folder's real contents and splices them in —
    /// the context menu's "Expand Contents".
    func expandSummarizedNode(_ node: FileNodeRecord) {
        guard canRefreshSubtree else { return }
        // Match the on-screen scan's options (a volume scan forces hidden
        // files on) so the spliced subtree isn't missing entries it had.
        var options = coordinator.snapshot.map { scanOptions(for: $0.target) }
            ?? preferences?.scanOptions ?? ScanOptions()
        // The user explicitly asked for this folder's contents;
        // re-summarizing it would make the action a no-op.
        options.autoSummarizeDirectories = false
        Task { [weak self] in
            guard let self else { return }
            let result = await self.coordinator.expandSummarizedNode(node, options: options)
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
