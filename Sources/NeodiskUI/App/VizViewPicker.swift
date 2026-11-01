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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = ChecklistSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.picked(_:))
        control.setAccessibilityLabel(NSLocalizedString("View", comment: "Toolbar view picker"))
        control.toolTip = NSLocalizedString("Switch views. Right-click to choose which ones show.", comment: "Toolbar view picker")
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
            for item in NSMenu.viewChecklistItems(views: picker.views, update: picker.update) { menu.addItem(item) }
        }
    }
}

extension NSMenu {
    /// Which views the toolbar picker shows, checked: its own right-click menu and the map's empty space share it,
    /// so a hidden view can come back from where it went.
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

    /// Right-clicking the map where there's no item (sunburst background, free or hidden space).
    @MainActor
    static func viewChecklist(model: NeodiskViewModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in viewChecklistItems(views: model.layout.views, update: { model.updateLayout($0) }) {
            menu.addItem(item)
        }
        return menu
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
