// What the canvas reads from and asks of the app: the tree, the focus and selection, colors, and the actions
// a click or key leads to. The window's model conforms; the canvas never owns app state.

import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit
import WinSDK

@MainActor
protocol VizCanvasModel: AnyObject {
    var store: FileTreeStore? { get }
    /// Bumped whenever the tree changes (scan progress, rescan, a move to the Recycle Bin).
    var storeGeneration: Int { get }
    /// The folder both maps are rooted at.
    var focusedRootID: String? { get }
    var selection: NodeSelection { get }
    var hoveredNodeID: String? { get set }
    var colorMode: TreemapColorMode { get }
    var highlight: TreemapHighlight? { get }
    var catalog: FileKindCatalog { get }
    var palette: VizPalette { get }
    var treemapStyle: TreemapStyle { get }
    var expandedAggregateIDs: Set<String> { get set }
    /// Nil unless the map shows them (volume scans at their root).
    var vizFreeSpaceBytes: Int64? { get }
    var vizHiddenSpaceBytes: Int64? { get }
    var isDarkTheme: Bool { get }
    var accentRGB: SIMD3<Float> { get }
    /// The opaque color behind the maps (gaps between cells, around the chart).
    var vizBackgroundRGB: SIMD3<Float> { get }

    func select(_ nodeID: String?)
    func toggleSelection(_ nodeID: String)
    /// False when there is nowhere to go (the canvas beeps).
    func moveSelectionInMap(_ move: TreeKeyboardNav.Move, extending: Bool, isRendered: ((String) -> Bool)?) -> Bool
    func selectAllInMap() -> Bool
    func drillIn(to nodeID: String?) -> Bool
    func drillIntoSelection() -> Bool
    func focusOut()

    /// Right-click or the menu key, after the selection was updated. `includeTrash` is false for a "smaller
    /// items" cell, which stands for its folder.
    func vizShowContextMenu(atScreen point: POINT, includeTrash: Bool)
    func vizShowInExplorer(nodeID: String)
    /// What the pointer is over, for the status bar; nil when nothing.
    func vizStatusText(_ text: String?)
    /// Keys the window acts on (Delete, shortcuts), offered before the canvas's own. True when handled.
    func vizHandleKey(vk: UInt32, ctrl: Bool, shift: Bool, alt: Bool) -> Bool
}
