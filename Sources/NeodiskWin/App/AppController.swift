// Connects the model to the window: each view's state is derived from the model in an observation, and the
// window's commands act on the model.

import CNeodiskWin
import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

@MainActor
final class AppController {
    let model: ShellModel
    let window: MainWindow
    private var outline: OutlineController!
    /// The treemap and sunburst.
    private var canvas: VizCanvas?
    private var observations: [ChangeObservation] = []
    private var workspace: ScanWorkspace { model.workspace }

    init(model: ShellModel) {
        self.model = model
        let settings = model.settings
        var canvas: VizCanvas?
        window = MainWindow(
            title: AppChannel.current.appName,
            width: Double(settings.windowWidth), height: Double(settings.windowHeight),
            makeCanvas: { parent in
                canvas = VizCanvas(parent: parent, model: model)
                return canvas?.hwnd
            }
        )
        self.canvas = canvas
        model.controller = self
        outline = OutlineController(view: window.outline, workspace: model.workspace)
        window.onCommand = { [unowned self] command in self.perform(command) }
        window.onClose = { [unowned self] in
            self.workspace.cancelScan()
            self.model.settings.saveNow()
        }
        window.onResize = { [unowned self] width, height in
            self.model.settings.windowWidth = Int(width.rounded())
            self.model.settings.windowHeight = Int(height.rounded())
        }
        window.onMaximize = { [unowned self] maximized in self.model.settings.windowMaximized = maximized }
        window.onThemeChange = { [unowned self] in
            self.refreshAll()
            self.canvas?.modelDidChange()
        }
        window.onDPIChange = { [unowned self] in self.canvas?.modelDidChange() }
        window.sidebar.onOpen = { [unowned self] id in self.openPaneRow(id) }
        window.onSearchChange = { [unowned self] text in self.outline.search(text) }
        window.onSearchSubmit = { [unowned self] in self.outline.pickFirstResult() }
        bind()
        Task { [weak self] in
            guard let self else { return }
            await self.workspace.refreshCachedScans(keeping: self.paneTargetIDs)
        }
    }

    func show() {
        window.show(maximized: model.settings.windowMaximized)
    }

    private var paneTargetIDs: Set<String> {
        Set(model.volumes.map { ShellModel.targetID(forVolume: $0.root) }
            + model.settings.recentFolders.map(ShellModel.targetID(forFolder:)))
    }

    // MARK: - Commands

    private func perform(_ command: MainWindow.Command) {
        switch command {
        case .back:
            if !workspace.focusBack() { MessageBeep(UINT(MB_OK)) }
        case .forward:
            if !workspace.focusForward() { MessageBeep(UINT(MB_OK)) }
        case .up:
            if workspace.canFocusOut { workspace.focusOut() } else { MessageBeep(UINT(MB_OK)) }
        case .scan:
            if workspace.target != nil, !workspace.isScanning { workspace.rescan() }
        case .stop:
            workspace.cancelScan()
        case .treemap:
            model.settings.vizMode = .treemap
        case .sunburst:
            model.settings.vizMode = .sunburst
        case .chooseFolder:
            chooseFolder()
        case .search:
            window.focusSearch()
        case .more:
            showMoreMenu()
        case .escape:
            workspace.select(nil)
        case .drillIn:
            if !workspace.drillIntoSelection() { MessageBeep(UINT(MB_OK)) }
        }
    }

    private func openPaneRow(_ id: String) {
        if let volume = model.volumes.first(where: { ShellModel.targetID(forVolume: $0.root) == id }) {
            model.openVolume(volume.root)
        } else if let folder = model.settings.recentFolders.first(where: { ShellModel.targetID(forFolder: $0) == id }) {
            model.openFolder(folder)
        }
    }

    func chooseFolder() {
        var buffer = [UInt16](repeating: 0, count: 32768)
        let picked = ndw_pick_folder(window.hwnd, L("Choose a Folder or Disk").wide, &buffer, Int32(buffer.count))
        guard picked != 0 else { return }
        model.openFolder(String(wideBuffer: buffer))
    }

    private func showMoreMenu() {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        let hasTarget = workspace.target != nil
        let items: [(UInt, String, Bool)] = [
            (1, L("Choose Folder…") + "\tCtrl+O", true),
            (2, L("Show in File Explorer"), hasTarget),
            (3, L("Copy Path"), hasTarget),
            (0, "", true),
            (4, L("About %@", AppChannel.current.appName), true),
        ]
        for (id, title, enabled) in items {
            if id == 0 {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            } else {
                _ = withWide(title) { AppendMenuW(menu, UINT(MF_STRING) | (enabled ? 0 : UINT(MF_GRAYED)), UINT_PTR(id), $0) }
            }
        }
        let anchor = window.commandBar.anchor(for: .more)
        let chosen = ndw_track_popup_menu(menu, anchor.x, anchor.y, window.hwnd)
        let path = workspace.selectedNode?.path ?? workspace.target?.url.path(percentEncoded: false)
        switch chosen {
        case 1: chooseFolder()
        case 2: if let path { FileActions.showInExplorer(path) }
        case 3: if let path { FileActions.copyToClipboard(path, owner: window.hwnd) }
        case 4:
            let text = "\(AppChannel.current.appName) \(AppVersion.display)"
            _ = withWide(text) { body in
                withWide(AppChannel.current.appName) { MessageBoxW(window.hwnd, body, $0, UINT(MB_OK | MB_ICONINFORMATION)) }
            }
        default: break
        }
    }

    // MARK: - Binding

    private func refreshAll() {
        for view in [window.sidebar, window.commandBar, window.header, window.statusBar, window.emptyState] as [SurfaceView] {
            view.invalidate()
        }
        updateSidebar()
    }

    private func bind() {
        observations.append(observeChanges { [unowned self] in self.updateSidebar() })
        observations.append(observeChanges { [unowned self] in self.updateChrome() })
        observations.append(observeChanges { [unowned self] in self.updateStatus() })
        observations.append(observeChanges { [unowned self] in self.updateCanvas() })
        observations.append(observeChanges { [unowned self] in
            // A new location starts with an empty search field.
            _ = self.workspace.target
            self.window.searchText = ""
        })
    }

    /// Everything the maps draw from; the canvas re-renders only when the scene's inputs moved.
    private func updateCanvas() {
        _ = workspace.storeGeneration
        _ = workspace.focusedRootID
        _ = workspace.selection
        _ = workspace.hoveredNodeID
        _ = workspace.expandedAggregateIDs
        _ = model.settings.treemapStyle
        _ = model.settings.paletteID
        canvas?.mode = model.settings.vizMode == .sunburst ? .sunburst : .treemap
        canvas?.modelDidChange()
    }

    // MARK: - Item actions (the maps' context menu)

    func showItemMenu(atScreen point: POINT) {
        guard let node = workspace.selectedNode, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        let items: [(UInt, String)] = [
            (1, L("Open")),
            (2, L("Show in File Explorer")),
            (3, L("Copy Path")),
        ]
        for (id, title) in items {
            _ = withWide(title) { AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(id), $0) }
        }
        switch ndw_track_popup_menu(menu, point.x, point.y, window.hwnd) {
        case 1: FileActions.open(node.path)
        case 2: FileActions.showInExplorer(node.path)
        case 3: FileActions.copyToClipboard(displayPath(workspace.selectedNodes.map(\.path).joined(separator: "\n")),
                                            owner: window.hwnd)
        default: break
        }
    }

    private func updateSidebar() {
        _ = model.minuteTick
        let cached = workspace.cachedScans
        let scanningID = workspace.isScanning ? workspace.target?.id : nil
        func scanned(_ id: String) -> String? {
            if id == scanningID { return L("Scanning…") }
            return cached[id].map { L("Scanned %@", DisplayFormatters.relativeDate($0.lastScanDate)) }
        }
        let volumeRows = model.volumes.map { volume -> SidebarView.Row in
            let id = ShellModel.targetID(forVolume: volume.root)
            var subtitle = L("%@ free of %@", NeodiskFormatters.size(volume.freeBytes), NeodiskFormatters.size(volume.totalBytes))
            if let scanned = scanned(id) { subtitle += " · " + scanned }
            let glyph: Glyph = switch volume.kind {
            case .fixed: .hardDrive
            case .removable: .usb
            case .network: .networkDrive
            }
            return SidebarView.Row(id: id, title: volume.title, subtitle: subtitle, tooltip: volume.root, glyph: glyph,
                                   usedFraction: volume.usedFraction)
        }
        let volumeIDs = Set(volumeRows.map(\.id))
        let folderRows = model.settings.recentFolders.compactMap { path -> SidebarView.Row? in
            let id = ShellModel.targetID(forFolder: path)
            guard !volumeIDs.contains(id), FileManager.default.fileExists(atPath: path) else { return nil }
            let name = URL(filePath: path).lastPathComponent
            var subtitle = cached[id].map { NeodiskFormatters.size($0.totalAllocatedSize) } ?? displayPath(path)
            if let scanned = scanned(id) { subtitle += " · " + scanned }
            return SidebarView.Row(id: id, title: name.isEmpty ? displayPath(path) : name, subtitle: subtitle, tooltip: displayPath(path),
                                   glyph: .folder, usedFraction: nil)
        }
        window.sidebar.state = SidebarView.State(
            sections: [
                SidebarView.Section(title: L("Volumes"), rows: volumeRows),
                SidebarView.Section(title: L("Folders"), rows: folderRows),
            ],
            selectedID: workspace.target?.id
        )
    }

    private func updateChrome() {
        let phase = workspace.phase
        let target = workspace.target
        let scanning = workspace.isScanning || phase == .restoring
        window.isScanning = scanning
        window.commandBar.state = CommandBarView.State(
            canGoBack: workspace.drillHistory.canGoBack,
            canGoForward: workspace.drillHistory.canGoForward,
            canGoUp: workspace.canFocusOut,
            canScan: target != nil,
            isScanning: scanning,
            showsSunburst: model.settings.vizMode == .sunburst,
            hasContent: workspace.store != nil
        )
        let title = model.title
        _ = withWide(target == nil ? AppChannel.current.appName : "\(title) - \(AppChannel.current.appName)") {
            SetWindowTextW(window.hwnd, $0)
        }
        switch (target, phase) {
        case (nil, _):
            window.emptyState.state = EmptyStateView.State(
                title: L("Choose a Location to Scan"),
                message: L("Scan folders and disks to see where space is going,\nthen clear out what you don't need."),
                showsButton: true
            )
            window.showsWorkspace = false
        case (.some(let target), .restoring):
            window.emptyState.state = EmptyStateView.State(
                title: L("Opening last scan of %@…", title.isEmpty ? target.displayName : title),
                message: "", showsButton: false
            )
            window.showsWorkspace = false
        case (_, .failed(let message)) where workspace.store == nil:
            window.emptyState.state = EmptyStateView.State(title: L("Couldn't Scan"), message: message, showsButton: true)
            window.showsWorkspace = false
        default:
            window.showsWorkspace = true
        }
        var progress: HeaderView.Progress?
        if workspace.isScanning {
            let metrics = workspace.metrics
            progress = HeaderView.Progress(
                sessionKey: "\(target?.id ?? "")|\(workspace.isRefreshing)",
                fraction: metrics.progressFraction,
                caption: progressCaption(metrics)
            )
        }
        window.header.state = HeaderView.State(title: title, caption: summary(), progress: progress)
    }

    private func progressCaption(_ metrics: ScanMetrics) -> String {
        if metrics.isFinalizing { return L("Finishing up…") }
        if metrics.isMergingChanges { return L("Merging changes…") }
        let counts = AppStrings.plural(
            metrics.filesVisited, one: "%@ file · %@", other: "%@ files · %@",
            metrics.filesVisited.formatted(), NeodiskFormatters.size(metrics.bytesDiscovered)
        )
        let percent = Int((min(1, max(0, metrics.progressFraction)) * 100).rounded(.down))
        let path = metrics.currentPath
        return path.isEmpty ? "\(percent) % · \(counts)" : "\(percent) % · \(counts) · \(displayPath(path))"
    }

    private func summary() -> String {
        _ = model.minuteTick
        guard let store = workspace.store else { return "" }
        var parts = [NeodiskFormatters.size(store.root.allocatedSize)]
        if let space = workspace.volumeSpace {
            parts.append(L("%@ free", NeodiskFormatters.size(space.availableCapacity)))
        }
        if workspace.isShowingPartialScan {
            parts.append(L("Stopped — showing partial results"))
        } else if let finished = workspace.snapshot?.finishedAt {
            parts.append(L("Scanned %@", DisplayFormatters.relativeDate(finished)))
        }
        return parts.joined(separator: " · ")
    }

    private func updateStatus() {
        guard let store = workspace.store else {
            window.statusBar.state = StatusBarView.State()
            return
        }
        var state = StatusBarView.State()
        if workspace.hoveredNode == nil, workspace.selection.isMultiple {
            let total = workspace.selection.topLevelIDs(in: store)
                .reduce(Int64(0)) { $0 &+ (store.node(id: $1)?.allocatedSize ?? 0) }
            state.name = L("%lld items selected", Int64(workspace.selection.count))
            state.detail = NeodiskFormatters.size(total)
        } else if let node = workspace.hoveredNode ?? workspace.selectedNode {
            state.name = node.name
            var parts = [NeodiskFormatters.size(node.allocatedSize)]
            if let share = NeodiskFormatters.percentage(part: node.allocatedSize, total: store.root.allocatedSize) {
                parts.append(L("%@ of scan", share))
            }
            if node.isDirectory {
                parts.append(AppStrings.plural(node.descendantFileCount, one: "%@ file", other: "%@ files",
                                               node.descendantFileCount.formatted()))
            }
            parts.append(displayPath(node.path))
            state.detail = parts.joined(separator: " · ")
        } else {
            let root = store.root
            state.name = AppStrings.plural(root.descendantFileCount, one: "%@ item", other: "%@ items",
                                           root.descendantFileCount.formatted())
            var parts = [NeodiskFormatters.size(root.allocatedSize)]
            if let hidden = workspace.hiddenSpaceBytes, hidden > 0 {
                parts.append(L("%@ hidden", NeodiskFormatters.size(hidden)))
            }
            state.detail = parts.joined(separator: " · ")
        }
        let warnings = workspace.warnings.count
        if warnings > 0 {
            state.warning = AppStrings.plural(warnings, one: "%@ file couldn't be read", other: "%@ files couldn't be read",
                                              warnings.formatted())
            state.warningTooltip = workspace.warnings.prefix(12).map { displayPath($0.path) }.joined(separator: "\n")
        }
        window.statusBar.state = state
    }
}
