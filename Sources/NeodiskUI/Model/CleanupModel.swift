// Cleanup: items collected from any view for the Trash, reviewed in the sidebar, moved after one confirmation.
// Each move re-checks the item right before it (TrashMover); moved items leave the tree in place, no rescan.

import AppKit
import Combine
import Observation
import NeodiskKit
import NeodiskAppModel

@MainActor
@Observable
final class CleanupModel {
    /// A short line under the Cleanup panel: why something wasn't added, or how a move went.
    struct Notice: Equatable {
        enum Kind: Equatable { case info, refused, moved, failed }
        let kind: Kind
        let text: String
        let id = UUID()
    }

    /// One pile per location, so switching locations doesn't lose what was collected.
    private var piles: [String: CleanupPile] = [:]
    /// Items whose last move failed, with the reason, until they're removed or moved.
    private(set) var failures: [String: String] = [:]
    /// Items whose move is running; the views mark them and refuse to act on them.
    private(set) var movingIDs: Set<String> = []
    private(set) var notice: Notice?
    /// True while a drag of scanned items is under way, so the panel can show where to drop them.
    var isDragInProgress = false
    /// Mirror of the Settings toggle.
    private(set) var isEnabled = true

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored weak var model: NeodiskViewModel?
    @ObservationIgnored private var cachedPolicy: TrashSafetyPolicy?
    @ObservationIgnored private var mountObserver: AnyCancellable?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Test seams.
    @ObservationIgnored var trashItem: TrashMover.TrashItem = TrashMover.systemTrash
    @ObservationIgnored var makePolicy: @Sendable () -> TrashSafetyPolicy = { TrashSafetyPolicy.live() }
    @ObservationIgnored private var isConfirming = false
    @ObservationIgnored var confirm: @MainActor (TrashConfirmation) async -> Bool = CleanupModel.presentConfirmation

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
        let notifications = NSWorkspace.shared.notificationCenter
        mountObserver = notifications.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: notifications.publisher(for: NSWorkspace.didUnmountNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.cachedPolicy = nil }
            }
    }

    private var policy: TrashSafetyPolicy {
        if let cachedPolicy { return cachedPolicy }
        let built = makePolicy()
        cachedPolicy = built
        return built
    }

    // MARK: - State

    private var targetID: String? { coordinator.snapshot?.target.id }
    private var store: FileTreeStore? { coordinator.snapshot?.treeStore }

    private var pile: CleanupPile {
        get { targetID.flatMap { piles[$0] } ?? CleanupPile() }
        set {
            guard let targetID else { return }
            piles[targetID] = newValue.isEmpty ? nil : newValue
        }
    }

    var itemIDs: [String] { pile.itemIDs }
    var isEmpty: Bool { pile.isEmpty }
    var isMoving: Bool { !movingIDs.isEmpty }

    var items: [FileNodeRecord] {
        guard let store else { return [] }
        return pile.nodes(in: store)
    }

    var totalSize: Int64 {
        guard let store else { return 0 }
        return pile.totalSize(in: store)
    }

    /// Exactly a collected item (the views outline these).
    func isCollected(_ id: String) -> Bool {
        pile.contains(id) || movingIDs.contains(id)
    }

    /// A collected item or something inside one (the lists dim these).
    func isInsideCollected(_ id: String) -> Bool {
        guard let store, !pile.isEmpty || !movingIDs.isEmpty else { return false }
        return pile.collectedItem(containing: id, in: store) != nil
            || store.isNodeOrDescendant(id, of: movingIDs)
    }

    /// How the views mark an item: lists dim `.inside` and up, maps outline the item itself.
    enum Mark: Equatable {
        case none
        /// Inside a collected (or moving) folder.
        case inside
        case collected
        case moving

        var isMarked: Bool { self != .none }
        /// The item itself, not something inside it.
        var isItem: Bool { self == .collected || self == .moving }

        /// The hover line for it, or nil.
        var hoverText: String? {
            switch self {
            case .none: nil
            case .inside: NSLocalizedString("In a folder in Cleanup", comment: "Hover line for an item inside a collected folder")
            case .collected: NSLocalizedString("In Cleanup", comment: "Hover line for a collected item")
            case .moving: NSLocalizedString("Moving to the Trash…", comment: "Hover line for an item being moved")
            }
        }
    }

    func mark(for id: String) -> Mark {
        if movingIDs.contains(id) { return .moving }
        if pile.contains(id) { return .collected }
        return isInsideCollected(id) ? .inside : .none
    }

    // MARK: - Eligibility

    /// Why nothing can be collected right now, or nil.
    var unavailableReason: String? {
        if !isEnabled {
            return NSLocalizedString("Moving items to the Trash is turned off in Settings.", comment: "Cleanup unavailable")
        }
        guard let snapshot = coordinator.snapshot else { return nil }
        if !snapshot.source.isPersistable {
            return NSLocalizedString("This scan was opened from a file, so its items can't be moved.", comment: "Cleanup unavailable")
        }
        if coordinator.isScanning {
            return NSLocalizedString("Wait for the scan to finish.", comment: "Cleanup unavailable")
        }
        if !snapshot.isComplete {
            return NSLocalizedString("This scan was stopped early. Rescan to move items to the Trash.", comment: "Cleanup unavailable")
        }
        return nil
    }

    /// Why this node can't be collected, or nil when it can.
    func refusalReason(for node: FileNodeRecord) -> String? {
        if let unavailableReason { return unavailableReason }
        guard let snapshot = coordinator.snapshot else { return nil }
        return policy.refusal(for: node, scanRootID: snapshot.root.id, in: snapshot.treeStore)?.localizedReason
    }

    /// False for what's already in, alone or with its folder.
    func canCollect(_ node: FileNodeRecord) -> Bool {
        refusalReason(for: node) == nil && !isMoving && !isInsideCollected(node.id)
    }

    // MARK: - Editing

    /// A drop on the panel: ids from the tree on screen, resolved now.
    func add(ids: [String]) {
        guard let store else { return }
        add(ids.compactMap { store.node(id: $0) })
    }

    /// What ⌘⌫ or the Cleanup menu item does to these items: add the ones not in yet (a folder takes what's inside
    /// it), else take out the collected ones. Items only inside a collected folder can't move on their own.
    enum Toggle: Equatable {
        case add([String])
        case remove([String])
        case none
    }

    func toggle(for nodes: [FileNodeRecord]) -> Toggle {
        guard let store else { return .none }
        let marks = nodes.map { ($0.id, mark(for: $0.id)) }
        let uncovered = marks.filter { $0.1 == .none }.map(\.0)
        if !uncovered.isEmpty {
            return .add(uncovered.count == 1 ? uncovered : store.topLevelNodeIDs(from: uncovered))
        }
        let collected = marks.filter { $0.1 == .collected }.map(\.0)
        return collected.isEmpty ? .none : .remove(collected)
    }

    /// ⌘⌫ and the context menus: collected items leave the pile, others join it.
    func toggle(_ nodes: [FileNodeRecord]) {
        switch toggle(for: nodes) {
        case .add(let ids):
            let added = Set(ids)
            add(nodes.filter { added.contains($0.id) })
        case .remove(let ids):
            remove(ids)
        case .none:
            NSSound.beep()
            if nodes.contains(where: { mark(for: $0.id) == .inside }), let text = Mark.inside.hoverText {
                show(Notice(kind: .refused, text: text))
            }
        }
    }

    /// Adds what may be collected. What can't go is counted under the panel with the first reason, so a large
    /// selection never drops items silently.
    func add(_ nodes: [FileNodeRecord]) {
        guard let store, !isMoving else { return }
        if let unavailableReason {
            NSSound.beep()
            show(Notice(kind: .refused, text: unavailableReason))
            return
        }
        let refusals = policy.refusals(for: nodes, scanRootID: store.rootID, in: store)
        let allowed = zip(nodes, refusals).compactMap { $1 == nil ? $0 : nil }
        let refusedCount = nodes.count - allowed.count
        let firstRefusal = refusals.lazy.compactMap { $0 }.first
        var updated = pile
        let added = updated.add(allowed.map(\.id), in: store)
        pile = updated
        for id in added { failures[id] = nil }
        guard let reason = firstRefusal?.localizedReason else {
            if !added.isEmpty { notice = nil }
            return
        }
        NSSound.beep()
        guard !added.isEmpty || refusedCount > 1 else {
            show(Notice(kind: .refused, text: reason))
            return
        }
        var parts: [String] = []
        if !added.isEmpty {
            parts.append(added.count == 1
                ? NSLocalizedString("Added 1 item.", comment: "Cleanup notice, some items refused")
                : String(format: NSLocalizedString("Added %lld items.", comment: "Cleanup notice, some items refused"), added.count))
        }
        parts.append(refusedCount == 1
            ? String(format: NSLocalizedString("1 item can't go to the Trash. %@", comment: "Cleanup notice; the first reason follows"), reason)
            : String(format: NSLocalizedString("%lld items can't go to the Trash. %@", comment: "Cleanup notice; the first reason follows"), refusedCount, reason))
        show(Notice(kind: .refused, text: parts.joined(separator: " ")))
    }

    func remove(_ ids: [String]) {
        guard !isMoving else { return }
        var updated = pile
        updated.remove(Set(ids))
        pile = updated
        for id in ids { failures[id] = nil }
    }

    func clear() {
        guard !isMoving else { return }
        for id in pile.itemIDs { failures[id] = nil }
        pile = CleanupPile()
    }

    /// Drops gone items after any tree change; a new tree of the same location keeps its pile, except items
    /// whose path now holds something else.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        guard let snapshot, snapshot.isComplete, var current = piles[snapshot.target.id] else { return }
        let changed = current.reconcile(with: snapshot.treeStore)
        piles[snapshot.target.id] = current.isEmpty ? nil : current
        // Kept while the item is in a pile, this location's or another's.
        failures = failures.filter { id, _ in piles.values.contains { $0.contains(id) } }
        if changed > 0 {
            show(Notice(kind: .info, text: changed == 1
                ? NSLocalizedString("1 item changed since you collected it and left Cleanup.", comment: "Cleanup notice")
                : String(format: NSLocalizedString("%lld items changed since you collected them and left Cleanup.", comment: "Cleanup notice"), changed)
            ), for: 10)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
    }

    func dismissNotice() {
        notice = nil
    }

    private func show(_ notice: Notice, for seconds: Double? = 6) {
        self.notice = notice
        noticeTask?.cancel()
        guard let seconds else { return }
        let id = notice.id
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.notice?.id == id else { return }
            self?.notice = nil
        }
    }

    // MARK: - Moving

    var canMoveToTrash: Bool {
        !isEmpty && !isMoving && !isConfirming && unavailableReason == nil
    }

    /// Asks once, then moves each item in turn. Failures stay in the pile with their reason.
    func moveAllToTrash() {
        guard canMoveToTrash, let snapshot = coordinator.snapshot else {
            NSSound.beep()
            return
        }
        let nodes = pile.nodes(in: snapshot.treeStore)
        guard !nodes.isEmpty else { return }
        let confirmation = TrashConfirmation(nodes: nodes, scannedAt: snapshot.finishedAt)
        isConfirming = true
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await self.confirm(confirmation)
            self.isConfirming = false
            guard confirmed else { return }
            await self.move(nodes, from: snapshot)
        }
    }

    private func move(_ confirmedNodes: [FileNodeRecord], from snapshot: ScanSnapshot) async {
        // The confirmation was modal, but a scan could have started behind it, and only what's still collected
        // and was asked about goes.
        guard canMoveToTrash, coordinator.snapshot?.id == snapshot.id else {
            NSSound.beep()
            return
        }
        let stillCollected = Set(pile.itemIDs)
        let nodes = confirmedNodes.filter { stillCollected.contains($0.id) }
        guard !nodes.isEmpty else { return }
        notice = nil
        movingIDs = Set(nodes.map(\.id))
        // Built fresh, off the main thread: mounts can appear without a notification.
        let makePolicy = makePolicy
        let freshPolicy = await Task.detached(priority: .userInitiated) { makePolicy() }.value
        cachedPolicy = freshPolicy
        let mover = TrashMover(policy: freshPolicy, trashItem: trashItem)
        let rootID = snapshot.root.id
        var gone: [FileNodeRecord] = []
        var movedCount = 0
        var movedBytes: Int64 = 0
        var failed: [String: String] = [:]
        for node in nodes {
            let result = await Task.detached(priority: .userInitiated) {
                mover.move(node, scanRootID: rootID)
            }.value
            switch result {
            case .success:
                gone.append(node)
                movedCount += 1
                movedBytes &+= node.allocatedSize
            case .failure(.missing):
                // Deleted some other way since the scan: the tree should drop it too.
                gone.append(node)
            case .failure(let failure):
                failed[node.id] = failure.localizedReason
            }
        }

        let targetID = snapshot.target.id
        var updated = piles[targetID] ?? CleanupPile()
        updated.remove(Set(gone.map(\.id)))
        piles[targetID] = updated.isEmpty ? nil : updated
        failures.merge(failed) { _, new in new }

        if !gone.isEmpty {
            let goneIDs = gone.map(\.id)
            // Found duplicates re-run from the hash cache, without reading files, rather than reset with the tree.
            let rehashesDuplicates = model?.duplicates.results != nil
            if coordinator.snapshot?.target.id == targetID {
                model?.prepareForRemoval(of: goneIDs, in: snapshot.treeStore)
            }
            if await coordinator.removeNodes(ids: goneIDs, fromTargetID: targetID) {
                model?.session.persistSplicedSnapshot(rotatesPrevious: false)
                if rehashesDuplicates { model?.duplicates.startScan() }
            } else if coordinator.snapshot?.target.id != targetID {
                // Another location is on screen now: its saved scan still gets the cut.
                await model?.session.removeNodesFromStoredScan(of: snapshot.target, ids: goneIDs)
            }
        }
        movingIDs = []
        report(moved: movedCount, bytes: movedBytes, missing: gone.count - movedCount, failed: failed.count)
    }

    private func report(moved: Int, bytes: Int64, missing: Int, failed: Int) {
        var parts: [String] = []
        // No "(Zero bytes)": a hard link's other name frees nothing, and the size would read as a mistake.
        if moved > 0, bytes == 0 {
            parts.append(moved == 1
                ? NSLocalizedString("Moved 1 item to the Trash.", comment: "Cleanup result")
                : String(format: NSLocalizedString("Moved %lld items to the Trash.", comment: "Cleanup result"), moved))
        } else if moved > 0 {
            parts.append(moved == 1
                ? String(format: NSLocalizedString("Moved 1 item (%@) to the Trash.", comment: "Cleanup result"), NeodiskFormatters.size(bytes))
                : String(format: NSLocalizedString("Moved %lld items (%@) to the Trash.", comment: "Cleanup result"), moved, NeodiskFormatters.size(bytes)))
        }
        if missing > 0 {
            parts.append(missing == 1
                ? NSLocalizedString("1 item was already gone.", comment: "Cleanup result")
                : String(format: NSLocalizedString("%lld items were already gone.", comment: "Cleanup result"), missing))
        }
        if failed > 0 {
            parts.append(failed == 1
                ? NSLocalizedString("1 item couldn't be moved; it's still in Cleanup.", comment: "Cleanup result")
                : String(format: NSLocalizedString("%lld items couldn't be moved; they're still in Cleanup.", comment: "Cleanup result"), failed))
            NSSound.beep()
        }
        guard !parts.isEmpty else { return }
        show(Notice(kind: failed > 0 ? .failed : .moved, text: parts.joined(separator: " ")), for: failed > 0 ? nil : 12)
    }

    // MARK: - Confirmation

    static func presentConfirmation(_ confirmation: TrashConfirmation) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        let move = alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: "Trash confirmation button"))
        move.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Trash confirmation button"))
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
