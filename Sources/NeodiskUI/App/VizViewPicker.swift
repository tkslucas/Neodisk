// The toolbar's view picker. AppKit, not a SwiftUI Picker: inside a toolbar item only a view's own `menu` wins the
// right-click over the toolbar's, and that menu is the checklist of views shown.

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
        let control = NSSegmentedControl()
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
        control.isEnabled = isEnabled
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
            let views = picker.views
            for view in VizView.allCases {
                let item = ClosureMenuItem(title: view.menuTitle) {
                    picker.update {
                        var updated = $0.views
                        updated.setHidden(view, !updated.isHidden(view))
                        $0.setViews(updated)
                    }
                }
                item.state = views.isHidden(view) ? .off : .on
                // The last view shown stays.
                item.isEnabled = views.isHidden(view) || views.canHide(view)
                menu.addItem(item)
            }
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

    var menuTitle: String {
        switch self {
        case .cushion: NSLocalizedString("Cushion Treemap", comment: "View menu")
        case .flat: NSLocalizedString("Flat Treemap", comment: "View menu")
        case .sunburst: NSLocalizedString("Sunburst", comment: "View menu")
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
