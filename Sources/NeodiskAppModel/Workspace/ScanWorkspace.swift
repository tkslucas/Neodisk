// One location on screen, independent of any toolkit: opening it from the snapshot cache or by scanning,
// streaming partial trees, keeping a finished map on screen while a rescan runs, and the selection and drill
// state the views share. The Windows app drives its views from it; the GTK app's AppModel can move onto it.

import Foundation
import NeodiskKit
import Observation

@MainActor
@Observable
package final class ScanWorkspace {
    package enum Phase: Equatable {
        case idle
        /// A live scan streams to the screen (partial trees, then final).
        case scanning
        /// A cached snapshot is decoding for display.
        case restoring
        case displaying
        case failed(String)
    }

    package private(set) var phase: Phase = .idle
    package private(set) var target: ScanTarget?
    /// A partial store while a scan streams, then the finished snapshot's.
    package private(set) var store: FileTreeStore? {
        didSet { storeGeneration &+= 1 }
    }
    /// Bumps with every tree swap, so work started against one tree can tell it was superseded.
    package private(set) var storeGeneration = 0
    package private(set) var snapshot: ScanSnapshot?
    package private(set) var metrics = ScanMetrics()
    /// A rescan behind a complete map: the old tree stays until the fresh one lands.
    package private(set) var isRefreshing = false
    package private(set) var warnings: [ScanWarning] = []
    package private(set) var volumeSpace: VolumeSpaceInfo?
    /// What the snapshot cache holds per target path.
    package private(set) var cachedScans: [String: CachedScanInfo] = [:]

    package var selection = NodeSelection()
    package var hoveredNodeID: String?
    /// The folder the views are drilled into; nil is the root.
    package var focusID: String? {
        didSet {
            // Every re-root is a step Back can return to, except the steps Back and Forward take themselves.
            guard focusID != oldValue, !isSteppingDrillHistory, let store else { return }
            drillHistory.recordLeaving(oldValue ?? store.rootID)
        }
    }
    package private(set) var drillHistory = DrillHistory()
    /// Folders whose "smaller items" cell was clicked open.
    package var expandedAggregateIDs: Set<String> = []

    @ObservationIgnored package let snapshotCache: ScanSnapshotCache
    /// The options behind every scan this starts.
    @ObservationIgnored package var scanOptions: () -> ScanOptions = { ScanOptions() }
    /// A folder was opened, for a recent-folders list.
    @ObservationIgnored package var didOpenFolder: ((String) -> Void)?
    /// Hands freed heap back to the system after a large tree goes away, where the platform needs asking.
    @ObservationIgnored package var releaseFreeMemory: (@Sendable () -> Void)?
    @ObservationIgnored private var isSteppingDrillHistory = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var memoryReleaseTask: Task<Void, Never>?

    package init(snapshotCache: ScanSnapshotCache = ScanSnapshotCache()) {
        self.snapshotCache = snapshotCache
    }

    // MARK: - Derived

    package var isScanning: Bool { phase == .scanning || isRefreshing }
    package var rootID: String? { store?.rootID }
    package var focusedRootID: String? { focusID ?? store?.rootID }
    package var selectedNodeID: String? { selection.primaryID }
    package var selectedNode: FileNodeRecord? { store?.node(id: selectedNodeID) }
    package var selectedNodes: [FileNodeRecord] { store.map { selection.nodes(in: $0) } ?? [] }
    package var hoveredNode: FileNodeRecord? { store?.node(id: hoveredNodeID) }
    package var canFocusOut: Bool { focusID != nil }

    /// Stop cut a scan short with no complete snapshot to fall back on: the views show what was read so far.
    package var isShowingPartialScan: Bool {
        phase == .displaying && snapshot == nil && store != nil
    }

    /// Used capacity the scan could not account for (other users' files, unreadable paths, metadata).
    package var hiddenSpaceBytes: Int64? {
        guard let volumeSpace, let store, target?.kind == .volume else { return nil }
        return volumeSpace.hiddenSpaceBytes(scannedBytes: store.root.allocatedSize)
    }

    // MARK: - Opening and scanning

    /// Shows `target` from the snapshot cache when it holds one (instant; the user decides when to rescan),
    /// otherwise by scanning it.
    package func open(_ target: ScanTarget) {
        cancelScan()
        self.target = target
        resetPerTargetState()
        if target.kind == .folder {
            didOpenFolder?(target.id)
        }
        phase = .restoring
        scanTask = Task { [weak self] in
            guard let self else { return }
            if let cached = await snapshotCache.loadSnapshot(for: target), !Task.isCancelled {
                display(cached)
                return
            }
            guard !Task.isCancelled else { return }
            await runScan(target, behindDisplayedSnapshot: false)
        }
    }

    /// Scans the current target again; a complete snapshot on screen stays until the fresh one lands.
    package func rescan() {
        guard let target else { return }
        cancelScan()
        let keepsDisplayedTree = snapshot != nil
        scanTask = Task { [weak self] in
            await self?.runScan(target, behindDisplayedSnapshot: keepsDisplayedTree)
        }
    }

    package func cancelScan() {
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
        selection.clear()
        hoveredNodeID = nil
        focusID = nil
        drillHistory = DrillHistory()
        expandedAggregateIDs = []
        isRefreshing = false
        volumeSpace = target.flatMap { $0.kind == .volume ? VolumeSpaceInfo.load(for: $0.url) : nil }
        scheduleMemoryRelease()
    }

    private func runScan(_ target: ScanTarget, behindDisplayedSnapshot: Bool) async {
        metrics = ScanMetrics()
        warnings = []
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
        let options = scanOptions()
        let stream = baseline == nil
            ? service.scan(target: target, options: options)
            : service.rescan(target: target, options: options, baselineProvider: { baseline })
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
                case .finished(let finished):
                    var progress = metrics
                    progress.progressFraction = 1
                    metrics = progress
                    display(finished)
                    await persist(finished)
                case .waitingForPermission:
                    // Only macOS raises privacy prompts; no shell on this model shows one.
                    break
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
        let previousFocus = focusID
        self.snapshot = snapshot
        store = snapshot.treeStore
        warnings = snapshot.scanWarnings
        isRefreshing = false
        phase = .displaying
        // A refresh keeps the user's place when it still exists.
        selection.reconcile(with: snapshot.treeStore)
        focusID = snapshot.treeStore.node(id: previousFocus) == nil ? nil : previousFocus
        if snapshot.target.kind == .volume {
            volumeSpace = VolumeSpaceInfo.load(for: snapshot.target.url)
        }
        scheduleMemoryRelease()
    }

    private func persist(_ snapshot: ScanSnapshot) async {
        do {
            try await snapshotCache.save(snapshot)
        } catch {
            DiagnosticLog.cache.error("could not cache the scan: \(error)")
        }
        await refreshCachedScans()
    }

    /// Re-indexes the snapshot cache, keeping only snapshots of `locations` (the ones the app still offers),
    /// the ones already indexed, and the location on screen.
    package func refreshCachedScans(keeping locations: Set<String> = []) async {
        var keep = locations.union(cachedScans.keys)
        if let target { keep.insert(target.id) }
        cachedScans = await snapshotCache.pruneAndIndex(keepingTargetIDs: keep)
    }

    private func scheduleMemoryRelease() {
        guard let releaseFreeMemory else { return }
        memoryReleaseTask?.cancel()
        memoryReleaseTask = Task {
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            await Task.detached(priority: .utility) { releaseFreeMemory() }.value
        }
    }

    // MARK: - Selection and focus

    package func select(_ nodeID: String?) {
        guard selection.ids != (nodeID.map { [$0] } ?? []) else { return }
        selection.replace(with: nodeID)
        widenFocus(toShow: nodeID)
    }

    /// A selection outside the drilled-in folder widens the focus to show it. Only the primary item counts.
    private func widenFocus(toShow nodeID: String?) {
        if let nodeID, let store, let focusID, !store.isAncestor(focusID, of: nodeID), focusID != nodeID {
            self.focusID = store.parent(of: nodeID)?.id
        }
    }

    /// The rows a list reports. A Ctrl- or Shift-gesture keeps the items the list doesn't show.
    package func select(fromList ids: [String], extending: Bool, listShows: (String) -> Bool) {
        let primary = selection.listPrimary(for: ids)
        selection.applyList(selected: ids, primary: primary, extending: extending, listShows: listShows)
        widenFocus(toShow: selection.primaryID)
    }

    /// Ctrl-click in a map: the item joins as the primary, or leaves.
    package func toggleSelection(_ nodeID: String) {
        selection.toggle(nodeID)
        if selection.primaryID == nodeID { widenFocus(toShow: nodeID) }
    }

    /// Shift+arrow in a map: the item joins as the primary.
    package func extendSelection(to nodeID: String) {
        selection.add(nodeID)
        widenFocus(toShow: nodeID)
    }

    /// An arrow key in a map, from the primary item. False (the caller beeps) when there is nowhere to go.
    package func moveSelectionInMap(
        _ move: TreeKeyboardNav.Move, extending: Bool, isRendered: ((String) -> Bool)?
    ) -> Bool {
        guard let store, let rootID = focusedRootID else { return false }
        switch TreeKeyboardNav.target(
            from: selectedNodeID, move: move, rootID: rootID, store: store, isRendered: isRendered
        ) {
        case .select(let id)?:
            if extending { extendSelection(to: id) } else { select(id) }
        case .drillOut(let folderID)? where !extending:
            focusOut()
            select(folderID)
        default:
            return false
        }
        return true
    }

    /// Ctrl+A in a map: everything the map is rooted at, one level down.
    @discardableResult
    package func selectAllInMap() -> Bool {
        guard let store, let rootID = focusedRootID else { return false }
        let children = store.children(of: rootID).filter { !$0.isSynthetic && $0.allocatedSize > 0 }
        guard !children.isEmpty else { return false }
        selection.replace(with: children.map(\.id), primary: children.first?.id)
        return true
    }

    /// Re-roots the views at `nodeID`, a folder (nil or the root: the whole scan).
    package func focus(on nodeID: String?) {
        guard let store else { return }
        guard let nodeID, nodeID != store.rootID else {
            focusID = nil
            return
        }
        guard let node = store.node(id: nodeID), node.isDirectory, store.containsChildren(id: nodeID) else { return }
        focusID = nodeID
    }

    /// A file drills into its folder, so it always makes progress. Lands the selection on the largest child;
    /// false (the caller beeps) when there is nowhere deeper.
    @discardableResult
    package func drillIn(to nodeID: String?) -> Bool {
        guard let store, let nodeID, let node = store.node(id: nodeID) else { return false }
        guard let folder = node.isDirectory ? node : store.parent(of: node.id),
              folder.isDirectory, folder.id != focusedRootID else { return false }
        let children = store.children(of: folder.id).filter { $0.allocatedSize > 0 }
        guard !children.isEmpty else { return false }
        focusID = folder.id == store.rootID ? nil : folder.id
        if node.isDirectory, !selection.isMultiple, let largest = children.first {
            selection.replace(with: largest.id)
        }
        return true
    }

    @discardableResult
    package func drillIntoSelection() -> Bool {
        drillIn(to: selectedNodeID)
    }

    /// Drills out one level; the folder left becomes the selection.
    package func focusOut() {
        guard let store, let focusID else { return }
        let parent = store.parent(of: focusID)?.id
        self.focusID = parent == store.rootID ? nil : parent
        if !selection.isMultiple { selection.replace(with: focusID) }
    }

    /// Back: the root shown before the last re-root. False (the caller beeps) when there is nowhere to go.
    @discardableResult
    package func focusBack() -> Bool {
        stepDrillHistory { history, current, isValid in history.goBack(from: current, isValid: isValid) }
    }

    /// Forward: undoes a Back.
    @discardableResult
    package func focusForward() -> Bool {
        stepDrillHistory { history, current, isValid in history.goForward(from: current, isValid: isValid) }
    }

    private func stepDrillHistory(_ step: (inout DrillHistory, String, (String) -> Bool) -> String?) -> Bool {
        guard let store, let current = focusedRootID else { return false }
        // A root a rescan removed is skipped (and dropped) on the way.
        guard let target = step(&drillHistory, current, { store.node(id: $0)?.isDirectory == true }) else {
            return false
        }
        isSteppingDrillHistory = true
        focusID = target == store.rootID ? nil : target
        isSteppingDrillHistory = false
        // Keep the selection while it's inside the map; otherwise land on the largest child, as drilling in does.
        if !selection.isMultiple, let selected = selectedNodeID,
           selected == target || !store.isAncestor(target, of: selected) {
            let children = store.children(of: target).filter { $0.allocatedSize > 0 }
            if let largest = children.max(by: { $0.allocatedSize < $1.allocatedSize }) {
                selection.replace(with: largest.id)
            }
        }
        return true
    }
}
