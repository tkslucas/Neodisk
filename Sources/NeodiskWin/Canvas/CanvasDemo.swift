// Dev hooks for the canvas, independent of the app window: a demo window over a synthetic tree or a real scan
// (NEODISK_CANVAS_DEMO=1), a scripted benchmark (NEODISK_CANVAS_BENCH=<report.txt>), and headless renders of
// every view to PNG (NEODISK_CANVAS_PNG=<prefix>). Synthetic trees: NEODISK_CANVAS_NODES=<count>; a real one:
// NEODISK_CANVAS_SCAN=<path>.

import CNeodiskCanvas
import Foundation
import NeodiskAppModel
import NeodiskKit
import SunburstCore
import TreemapKit
import WinSDK

enum CanvasDemo {
    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["NEODISK_CANVAS_DEMO"] == "1" || environment["NEODISK_CANVAS_BENCH"] != nil
            || environment["NEODISK_CANVAS_PNG"] != nil
    }

    @MainActor
    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is a macro cast the importer can't express.
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        let adapter = D2DCanvas.adapterDescription
        CanvasLog.write("canvas: adapter \(adapter.name) software=\(adapter.isSoftware)")
        guard let loaded = loadStore() else { return 1 }
        let (store, label) = loaded
        let model = DemoModel(store: store)
        model.isDarkTheme = environment["NEODISK_CANVAS_THEME"] != "light"
        if let style = environment["NEODISK_TREEMAP_STYLE"], style == "flat" { model.treemapStyle = .flat }
        switch environment["NEODISK_CANVAS_COLOR"] {
        case "branch": model.colorMode = .branch
        case "age": model.colorMode = .age(referenceDate: Date())
        default: break
        }

        if let prefix = environment["NEODISK_CANVAS_PNG"] {
            return renderPNGs(model: model, prefix: prefix)
        }
        let window = DemoWindow(model: model, title: label)
        if environment["NEODISK_VIZ_MODE"] == "sunburst" { window.canvas.mode = .sunburst }
        if let report = environment["NEODISK_CANVAS_BENCH"] {
            return CanvasBenchmark(window: window, model: model, label: label, adapter: adapter).run(reportPath: report)
        }
        return window.runLoop()
    }

    // MARK: - Trees

    private static func loadStore() -> (FileTreeStore, String)? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["NEODISK_CANVAS_SCAN"] {
            let start = ContinuousClock.now
            guard let store = scan(path) else {
                CanvasLog.write("canvas: scan of \(path) failed")
                return nil
            }
            let label = "scan of \(path), \(store.allNodes.count) nodes"
            CanvasLog.write(String(format: "canvas: %@ in %.1f s", label, Clock.milliseconds(since: start) / 1000))
            return (store, label)
        }
        let count = Int(environment["NEODISK_CANVAS_NODES"] ?? "") ?? 200_000
        let start = ContinuousClock.now
        let store = SyntheticTree.make(nodeCount: count)
        let label = "synthetic tree, \(store.allNodes.count) nodes"
        CanvasLog.write(String(format: "canvas: %@ built in %.1f s", label, Clock.milliseconds(since: start) / 1000))
        return (store, label)
    }

    private static func scan(_ path: String) -> FileTreeStore? {
        final class Box: @unchecked Sendable { var store: FileTreeStore? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let target = ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
            do {
                for try await event in ScanEngine().scan(target: target, options: ScanOptions()) {
                    if case .finished(let snapshot) = event { box.store = snapshot.treeStore }
                }
            } catch {
                CanvasLog.write("canvas: scan error \(error)")
            }
            done.signal()
        }
        done.wait()
        return box.store
    }

    // MARK: - Headless

    @MainActor
    private static func renderPNGs(model: DemoModel, prefix: String) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let parts = (environment["NEODISK_CANVAS_SIZE"] ?? "1280x800").split(separator: "x").compactMap { Double($0) }
        let size = parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1280, height: 800)
        let scale = Double(environment["NEODISK_CANVAS_SCALE"] ?? "") ?? 1
        var failures: Int32 = 0
        if let focus = environment["NEODISK_CANVAS_FOCUS"] { _ = model.drillIn(to: focus) }
        let views: [(String, TreemapStyle, VizCanvas.Mode)] = [
            ("cushion", .cushion, .treemap), ("flat", .flat, .treemap), ("sunburst", .cushion, .sunburst),
        ]
        for (name, style, mode) in views {
            model.treemapStyle = style
            guard let host = HeadlessCanvas(model: model, size: size, scale: scale) else { return 1 }
            let start = ContinuousClock.now
            let path = "\(prefix)-\(name).png"
            if host.renderPNG(mode: mode, to: path) {
                CanvasLog.write(String(format: "canvas: wrote %@ in %.0f ms", path, Clock.milliseconds(since: start)))
                for key in ["treemap.scene", "treemap.raster", "treemap.labels", "treemap.labelImage", "sunburst.layout",
                            "sunburst.raster"] where !host.stats.values(key).isEmpty {
                    CanvasLog.write("  " + host.stats.summary(key))
                }
            } else {
                CanvasLog.write("canvas: rendering \(path) failed")
                failures += 1
            }
        }
        return failures
    }
}

/// Renders one frame with the window's code into an offscreen bitmap.
@MainActor
final class HeadlessCanvas: CanvasHost {
    let model: VizCanvasModel
    let viewSize: CGSize
    let scale: Double
    let device: D2DCanvas?
    let mailbox = CanvasMailbox(isInline: true)
    let stats = CanvasStats()
    private var mode = VizCanvas.Mode.treemap
    private lazy var treemap = TreemapPresenter(host: self)
    private lazy var sunburst = SunburstPresenter(host: self)

    init?(model: VizCanvasModel, size: CGSize, scale: Double) {
        self.model = model
        self.viewSize = size
        self.scale = scale
        guard let device = D2DCanvas.offscreen(
            pixelWidth: Int((size.width * scale).rounded()), pixelHeight: Int((size.height * scale).rounded()),
            dpi: Float(96 * scale)
        ) else { return nil }
        self.device = device
    }

    func isShowing(_ presenter: AnyObject) -> Bool {
        mode == .treemap ? presenter === treemap : presenter === sunburst
    }

    func invalidate() {}
    func runInBackground(_ job: @escaping @Sendable () -> Void) { job() }
    func beep() {}
    func screenPoint(for viewPoint: CGPoint) -> POINT { POINT(x: LONG(viewPoint.x), y: LONG(viewPoint.y)) }
    var hasFocus: Bool { false }
    var showsFocusRing: Bool { false }

    func renderPNG(mode: VizCanvas.Mode, to path: String) -> Bool {
        self.mode = mode
        guard let device else { return false }
        switch mode {
        case .treemap: treemap.modelDidChange()
        case .sunburst: sunburst.modelDidChange()
        }
        guard device.begin(clear: NDColor(model.vizBackgroundRGB)) else { return false }
        switch mode {
        case .treemap: treemap.draw(into: device, size: viewSize)
        case .sunburst: sunburst.draw(into: device, size: viewSize)
        }
        guard device.end(present: .none) else { return false }
        return device.savePNG(to: path)
    }
}

// MARK: - Model

/// The window model's part the canvas reads, over one tree, with the other apps' selection and drill rules.
@MainActor
final class DemoModel: VizCanvasModel {
    let store: FileTreeStore?
    var storeGeneration = 1
    var focusID: String?
    var selection = NodeSelection()
    var hoveredNodeID: String?
    var colorMode = TreemapColorMode.kind
    var highlight: TreemapHighlight?
    let catalog: FileKindCatalog
    var palette = VizPalette.standard
    var treemapStyle = TreemapStyle.cushion
    var expandedAggregateIDs: Set<String> = [] { didSet { changed() } }
    var vizFreeSpaceBytes: Int64? { nil }
    var vizHiddenSpaceBytes: Int64? { nil }
    var isDarkTheme = true
    var accentRGB = SIMD3<Float>(0, 120, 212) / 255
    var vizBackgroundRGB: SIMD3<Float> { isDarkTheme ? SIMD3(32, 32, 32) / 255 : SIMD3(249, 249, 249) / 255 }
    weak var canvas: VizCanvas?
    var onStatus: ((String?) -> Void)?
    var onKey: ((UInt32, Bool) -> Bool)?

    init(store: FileTreeStore) {
        self.store = store
        catalog = FileKindCatalog.build(from: store)
    }

    var focusedRootID: String? { focusID ?? store?.rootID }

    private func changed() {
        canvas?.modelDidChange()
    }

    func select(_ nodeID: String?) {
        selection.replace(with: nodeID)
        changed()
    }

    func toggleSelection(_ nodeID: String) {
        selection.toggle(nodeID)
        changed()
    }

    func moveSelectionInMap(_ move: TreeKeyboardNav.Move, extending: Bool, isRendered: ((String) -> Bool)?) -> Bool {
        guard let store, let rootID = focusedRootID else { return false }
        switch TreeKeyboardNav.target(
            from: selection.primaryID, move: move, rootID: rootID, store: store, isRendered: isRendered
        ) {
        case .select(let id)?:
            if extending { selection.add(id) } else { selection.replace(with: id) }
        case .drillOut(let folderID)? where !extending:
            focusOut()
            selection.replace(with: folderID)
        default:
            return false
        }
        changed()
        return true
    }

    func selectAllInMap() -> Bool {
        guard let store, let rootID = focusedRootID else { return false }
        let children = store.children(of: rootID).filter { !$0.isSynthetic && $0.allocatedSize > 0 }
        guard !children.isEmpty else { return false }
        selection.replace(with: children.map(\.id), primary: children.first?.id)
        changed()
        return true
    }

    func drillIn(to nodeID: String?) -> Bool {
        guard let store, let nodeID, let node = store.node(id: nodeID) else { return false }
        guard let folder = node.isDirectory ? node : store.parent(of: node.id),
              folder.isDirectory, folder.id != focusedRootID else { return false }
        let children = store.children(of: folder.id).filter { $0.allocatedSize > 0 }
        guard !children.isEmpty else { return false }
        focusID = folder.id == store.rootID ? nil : folder.id
        if node.isDirectory, !selection.isMultiple, let largest = children.first {
            selection.replace(with: largest.id)
        }
        changed()
        return true
    }

    func drillIntoSelection() -> Bool {
        drillIn(to: selection.primaryID)
    }

    func focusOut() {
        guard let store, let focusID else { return }
        let parent = store.parent(of: focusID)?.id
        self.focusID = parent == store.rootID ? nil : parent
        if !selection.isMultiple { selection.replace(with: focusID) }
        changed()
    }

    func vizShowContextMenu(atScreen point: POINT, includeTrash: Bool) {
        CanvasLog.write("canvas: context menu at \(point.x),\(point.y) trash=\(includeTrash)")
    }

    func vizShowInExplorer(nodeID: String) {
        CanvasLog.write("canvas: show in File Explorer \(nodeID)")
    }

    func vizStatusText(_ text: String?) {
        onStatus?(text)
    }

    func vizHandleKey(vk: UInt32, ctrl: Bool, shift: Bool, alt: Bool) -> Bool {
        onKey?(vk, ctrl) ?? false
    }
}

// MARK: - Synthetic tree

/// A deterministic tree shaped like a real disk: folders a few levels deep, most bytes in a few big files,
/// common extensions so the kind colors vary.
enum SyntheticTree {
    private static let extensions = ["dll", "exe", "sys", "png", "jpg", "mp4", "txt", "json", "log", "pdf", "zip",
                                     "cab", "msi", "mui", "dat", "db", "xml", "js", "swift", "wav"]

    static func make(nodeCount: Int, seed: UInt64 = 0x5EED) -> FileTreeStore {
        var random = seed
        func next() -> UInt64 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return random >> 33
        }
        func uniform() -> Double { Double(next() % 1_000_000) / 1_000_000 }

        var childrenByID: [String: [FileNodeRecord]] = [:]
        childrenByID.reserveCapacity(nodeCount / 16)
        let rootPath = "C:\\Synthetic"

        /// Returns the folder's record (sizes are its subtree's).
        func folder(_ path: String, name: String, depth: Int, budget: Int) -> FileNodeRecord {
            var children: [FileNodeRecord] = []
            var remaining = budget
            // The deepest level takes whatever budget is left as files, so the tree has exactly `nodeCount` nodes.
            let fileCount = min(remaining, depth == 0 ? 6 : depth >= 9 ? remaining : Int(4 + uniform() * 40))
            for index in 0..<fileCount {
                let ext = extensions[Int(next() % UInt64(extensions.count))]
                let name = "file\(index).\(ext)"
                // Log-uniform from 1 KB to ~4 GB, skewed small.
                let size = Int64(1024 * pow(2, pow(uniform(), 2.2) * 22))
                children.append(FileNodeRecord(
                    id: path + "\\" + name, path: path + "\\" + name, name: name, isDirectory: false,
                    isSymbolicLink: false, allocatedSize: size, logicalSize: size, descendantFileCount: 1,
                    lastModified: Date(timeIntervalSince1970: 1_600_000_000 + uniform() * 150_000_000),
                    isPackage: false, isAccessible: true, isSelfAccessible: true, isSynthetic: false,
                    isAutoSummarized: false
                ))
            }
            remaining -= fileCount
            if remaining > 0 {
                let folderCount = depth == 0 ? 12 : Int(2 + uniform() * 9)
                // Uneven split: a few folders hold most of the tree, as on a real disk.
                var weights = (0..<folderCount).map { _ in pow(uniform(), 3) + 0.01 }
                let total = weights.reduce(0, +)
                weights = weights.map { $0 / total }
                var assigned = 0
                var cumulative = 0.0
                for (index, weight) in weights.enumerated() {
                    cumulative += weight * Double(remaining)
                    let end = index == folderCount - 1 ? remaining : min(remaining, Int(cumulative.rounded()))
                    let share = end - assigned
                    guard share > 0 else { continue }
                    assigned = end
                    let name = "folder\(depth)-\(index)"
                    children.append(folder(path + "\\" + name, name: name, depth: depth + 1, budget: share - 1))
                }
            }
            childrenByID[path] = children
            var size: Int64 = 0
            var files = 0
            for child in children {
                size += child.allocatedSize
                files += child.isDirectory ? child.descendantFileCount : 1
            }
            return FileNodeRecord(
                id: path, path: path, name: name, isDirectory: true, isSymbolicLink: false, allocatedSize: size,
                logicalSize: size, descendantFileCount: files, lastModified: nil, isPackage: false, isAccessible: true,
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
            )
        }

        let root = folder(rootPath, name: "Synthetic", depth: 0, budget: nodeCount - 1)
        return FileTreeStore(root: root, childrenByID: childrenByID)
    }
}
