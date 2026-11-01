// The toolbar's view picker. AppKit, not a SwiftUI Picker: a SwiftUI context menu never sees the right-click in a
// toolbar, so the control pops the checklist of views shown itself.

import AppKit
import SwiftUI
import NeodiskAppModel

struct VizViewPicker: NSViewRepresentable {
    let views: ItemLayout<VizView>
    let current: VizView
    let isEnabled: Bool
    let update: ((inout WorkspaceLayout) -> Void) -> Void
    /// Its right-click menu: what the window shows (views, file list, status bar).
    let menuItems: () -> [NSMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = ChecklistSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.picked(_:))
        control.setAccessibilityLabel(NSLocalizedString("View", comment: "Toolbar view picker"))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        control.menu = menu
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.picker = self
        let visible = views.visible
        if control.segmentCount != visible.count || context.coordinator.shown != visible {
            context.coordinator.shown = visible
            control.segmentCount = visible.count
            for (index, view) in visible.enumerated() {
                control.setImage(
                    NSImage(systemSymbolName: view.systemImage, accessibilityDescription: view.pickerTitle),
                    forSegment: index
                )
                // Each segment names its view; the two treemap glyphs look alike.
                control.setToolTip(view.menuTitle, forSegment: index)
            }
        }
        control.selectedSegment = visible.firstIndex(of: current) ?? -1
        // Each segment too: a disabled control alone still drew its segments as clickable.
        control.isEnabled = isEnabled
        for index in 0..<control.segmentCount where control.isEnabled(forSegment: index) != isEnabled {
            control.setEnabled(isEnabled, forSegment: index)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var picker: VizViewPicker?
        var shown: [VizView] = []

        @objc func picked(_ sender: NSSegmentedControl) {
            guard shown.indices.contains(sender.selectedSegment) else { return }
            let view = shown[sender.selectedSegment]
            picker?.update { $0.pick(view) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let picker else { return }
            for item in picker.menuItems() { menu.addItem(item) }
        }
    }
}

extension NSMenu {
    /// Which views the toolbar picker shows, checked.
    static func viewChecklistItems(
        views: ItemLayout<VizView>,
        update: @escaping ((inout WorkspaceLayout) -> Void) -> Void
    ) -> [NSMenuItem] {
        VizView.allCases.map { view in
            let item = ClosureMenuItem(title: view.menuTitle) {
                update { $0.setHidden(view, !$0.views.isHidden(view)) }
            }
            item.state = views.isHidden(view) ? .off : .on
            // The last view shown stays.
            item.isEnabled = views.isHidden(view) || views.canHide(view)
            return item
        }
    }

    /// What the window shows: the views, where the file list sits and whether it shows, the status bar. The
    /// toolbar picker's right-click and the map's empty space share it, so anything hidden comes back from there
    /// as from the View menu (`WorkspaceLayoutMenuItems` is its SwiftUI twin for SwiftUI context menus).
    @MainActor
    static func workspaceLayoutItems(model: NeodiskViewModel) -> [NSMenuItem] {
        let menu = NSMenu()
        for item in viewChecklistItems(views: model.layout.views, update: { model.updateLayout($0) }) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addFileListLayoutItems(model: model)
        menu.addItem(.separator())
        let showsStatusBar = model.showsStatusBar
        menu.addItem(ClosureMenuItem(title: showsStatusBar
            ? NSLocalizedString("Hide Status Bar", comment: "Layout menu")
            : NSLocalizedString("Show Status Bar", comment: "Layout menu")
        ) { model.setStatusBarShown(!showsStatusBar) })
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// Right-clicking the map where there's no item (sunburst background, free or hidden space).
    @MainActor
    static func workspaceLayout(model: NeodiskViewModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in workspaceLayoutItems(model: model) { menu.addItem(item) }
        return menu
    }

    /// An item's menu on the map ends with the way back for a hidden file list, since the map has hardly any
    /// empty space to right-click. The status bar starts hidden, so it waits in the layout menus instead.
    @MainActor
    func addRestoreItems(model: NeodiskViewModel) {
        var restore: [NSMenuItem] = []
        if !model.layout.showsList {
            restore.append(ClosureMenuItem(title: NSLocalizedString("Show File List", comment: "Layout menu")) {
                model.updateLayout { $0.setListShown(true) }
            })
        }
        guard !restore.isEmpty else { return }
        addItem(.separator())
        restore.forEach(addItem)
    }
}

/// The SwiftUI side of `NSMenu.workspaceLayoutItems`, for the path bar's and status bar's context menus.
struct WorkspaceLayoutMenuItems: View {
    let model: NeodiskViewModel

    var body: some View {
        let views = model.layout.views
        ForEach(VizView.allCases, id: \.self) { view in
            Toggle(view.menuTitle, isOn: Binding(
                get: { !views.isHidden(view) },
                set: { _ in model.updateLayout { $0.setHidden(view, !$0.views.isHidden(view)) } }
            ))
            .disabled(!views.isHidden(view) && !views.canHide(view))
        }
        Divider()
        ForEach(OutlinePosition.menuOrder, id: \.self) { position in
            Toggle(position.menuTitle, isOn: Binding(
                get: { model.layout.showsList(at: position) },
                set: { _ in model.updateLayout { $0.placeList(position) } }
            ))
            .disabled(!model.layout.canPlaceList(position))
        }
        Button(model.layout.showsList ? "Hide File List" : "Show File List") {
            model.updateLayout { $0.setListShown(!$0.showsList) }
        }
        Divider()
        Button(model.showsStatusBar ? "Hide Status Bar" : "Show Status Bar") {
            model.setStatusBarShown(!model.showsStatusBar)
        }
    }
}

/// Pops its own menu. The toolbar takes a right-click before any view in it does, so this watches for it.
private final class ChecklistSegmentedControl: NSSegmentedControl {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        // Icon and Text mode labels the toolbar item hosting the picker, as Finder's view switcher reads "View".
        DispatchQueue.main.async { [weak self] in
            guard let self, let items = window?.toolbar?.items else { return }
            for item in items where item.view.map({ isDescendant(of: $0) }) == true {
                item.label = NSLocalizedString("View", comment: "Toolbar view picker")
                item.paletteLabel = item.label
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let menu, isEnabled, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }
}

extension VizView {
    var pickerTitle: String {
        switch self {
        case .cushion: NSLocalizedString("Cushion", comment: "Toolbar view picker")
        case .flat: NSLocalizedString("Flat", comment: "Toolbar view picker")
        case .sunburst: NSLocalizedString("Sunburst", comment: "Toolbar view picker")
        }
    }

    var systemImage: String {
        switch self {
        case .cushion: "square.split.bottomrightquarter"
        case .flat: "rectangle.3.group"
        case .sunburst: "chart.pie"
        }
    }
}
