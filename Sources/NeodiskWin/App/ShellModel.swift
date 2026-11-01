// The Windows app's state: the shared ScanWorkspace (one location, its scan, selection and drill state), the
// settings, and the volumes the pane offers. The views observe it; the canvas reads the same names.

import Foundation
import NeodiskAppModel
import NeodiskKit
import Observation
import TreemapKit
import WinSDK

@MainActor
@Observable
final class ShellModel {
    let settings: Settings
    let workspace: ScanWorkspace
    private(set) var volumes: [Volume] = []
    /// Ticks once a minute, so "Scanned 5 minutes ago" stays current.
    private(set) var minuteTick = 0
    @ObservationIgnored private var minuteTimer: Task<Void, Never>?
    /// Acts on the window for the maps (menus, File Explorer).
    @ObservationIgnored weak var controller: AppController?

    init(settings: Settings, workspace: ScanWorkspace = ScanWorkspace()) {
        self.settings = settings
        self.workspace = workspace
        workspace.scanOptions = { [unowned settings] in settings.scanOptions }
        workspace.didOpenFolder = { [unowned settings] path in settings.noteRecentFolder(path) }
        workspace.releaseFreeMemory = {
            // The process heap gives back what a released tree held.
            _ = HeapCompact(GetProcessHeap(), 0)
        }
        reloadVolumes()
        minuteTimer = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(60))) != nil {
                self?.minuteTick &+= 1
            }
        }
    }

    func reloadVolumes() {
        let fresh = Volumes.current()
        if fresh != volumes { volumes = fresh }
    }

    /// The target id a volume's scan uses, for matching pane rows to the location on screen.
    static func targetID(forVolume root: String) -> String {
        ScanTarget(url: URL(filePath: root, directoryHint: .isDirectory), kind: .volume).id
    }

    static func targetID(forFolder path: String) -> String {
        ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: .folder).id
    }

    func openVolume(_ root: String) {
        workspace.open(ScanTarget(url: URL(filePath: root, directoryHint: .isDirectory), kind: .volume))
    }

    func openFolder(_ path: String) {
        // A drive root picked as a folder is still the volume.
        let isRoot = path.count <= 3 && path.dropFirst().hasPrefix(":")
        workspace.open(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: isRoot ? .volume : .folder))
    }

    /// The volume or folder name the window shows for the location on screen.
    var title: String {
        guard let target = workspace.target else { return AppChannel.current.appName }
        if target.kind == .volume, let volume = volumes.first(where: { Self.targetID(forVolume: $0.root) == target.id }) {
            return volume.title
        }
        return target.displayName
    }

    // MARK: - What the canvas reads (names shared with the canvas protocol)

    var store: FileTreeStore? { workspace.store }
    var storeGeneration: Int { workspace.storeGeneration }
    var focusedRootID: String? { workspace.focusedRootID }
    var selection: NodeSelection {
        get { workspace.selection }
        set { workspace.selection = newValue }
    }
    var hoveredNodeID: String? {
        get { workspace.hoveredNodeID }
        set { workspace.hoveredNodeID = newValue }
    }
    var expandedAggregateIDs: Set<String> {
        get { workspace.expandedAggregateIDs }
        set { workspace.expandedAggregateIDs = newValue }
    }
    /// Without a statistics panel, the map shows the structural branch hues.
    var colorMode: TreemapColorMode { .branch }
    var highlight: TreemapHighlight? { nil }
    var catalog: FileKindCatalog { .empty }
    var palette: VizPalette { settings.palette }
    var treemapStyle: TreemapStyle { settings.treemapStyle }
    var isDarkTheme: Bool { Theme.current.isDark }
    var accentRGB: SIMD3<Float> { Theme.current.accentFill.simd }
    var vizBackgroundRGB: SIMD3<Float> { Theme.current.layer.simd }

    func select(_ nodeID: String?) { workspace.select(nodeID) }
    func toggleSelection(_ nodeID: String) { workspace.toggleSelection(nodeID) }
    func moveSelectionInMap(_ move: TreeKeyboardNav.Move, extending: Bool, isRendered: ((String) -> Bool)?) -> Bool {
        workspace.moveSelectionInMap(move, extending: extending, isRendered: isRendered)
    }
    @discardableResult func selectAllInMap() -> Bool { workspace.selectAllInMap() }
    @discardableResult func drillIn(to nodeID: String?) -> Bool { workspace.drillIn(to: nodeID) }
    @discardableResult func drillIntoSelection() -> Bool { workspace.drillIntoSelection() }
    func focusOut() { workspace.focusOut() }
}
