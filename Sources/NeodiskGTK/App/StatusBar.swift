// The hovered or selected item's name, size and path. Right-click hides it; the primary menu brings it back.

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class StatusBar {
    let widget: GPtr
    private let model: AppModel
    private let swatch = ColorSwatch()
    private let nameLabel: GPtr
    private let detailLabel: GPtr
    private let warningLabel: GPtr
    private var menu: GPtr?
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model
        nameLabel = Widgets.label("", ellipsize: true)
        detailLabel = Widgets.label("", classes: ["dim-label", "neodisk-numeric"], ellipsize: true)
        gtk_widget_set_hexpand(ptr(detailLabel), gbool(true))
        warningLabel = Widgets.label("", classes: ["warning", "neodisk-caption"])
        widget = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, classes: ["neodisk-statusbar"], [
            swatch.widget, nameLabel, detailLabel, warningLabel,
        ])
        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self] _, x, y in self.showMenu(at: CGPoint(x: x, y: y)) }
        gtk_widget_add_controller(ptr(widget), ptr(click))
        tokens.append(track { [unowned self] in self.update() })
    }

    func showMenu(at point: CGPoint) {
        Widgets.popupMenu(&menu, sections: [[(L("Hide Status Bar"), "win.hide-status-bar")]], on: widget, at: point)
    }

    private func update() {
        let node = model.hoveredNode ?? model.selectedNode
        guard let store = model.store, model.preferences.showsStatusBar else {
            Widgets.setVisible(widget, false)
            return
        }
        Widgets.setVisible(widget, true)
        if model.hoveredNode == nil, model.selection.isMultiple {
            // Several selected: how many, and their size (what's inside a selected folder counts once).
            let total = model.selection.topLevelIDs(in: store)
                .reduce(Int64(0)) { $0 &+ (store.node(id: $1)?.allocatedSize ?? 0) }
            gtk_label_set_text(ptr(nameLabel), L("%lld items selected", Int64(model.selection.count)))
            gtk_label_set_text(ptr(detailLabel), NeodiskFormatters.size(total))
            swatch.rgb = nil
        } else if let node {
            gtk_label_set_text(ptr(nameLabel), node.name)
            var parts = [NeodiskFormatters.size(node.allocatedSize)]
            if let share = NeodiskFormatters.percentage(part: node.allocatedSize, total: store.root.allocatedSize) {
                parts.append(L("%@ of scan", share))
            }
            if node.isDirectory {
                parts.append(AppStrings.plural(node.descendantFileCount, one: "%@ file", other: "%@ files", node.descendantFileCount.formatted()))
            }
            parts.append(node.path)
            gtk_label_set_text(ptr(detailLabel), parts.joined(separator: " · "))
            swatch.rgb = model.catalog.rgb(for: node)
        } else {
            let root = store.root
            gtk_label_set_text(ptr(nameLabel), AppStrings.plural(root.descendantFileCount, one: "%@ item", other: "%@ items", root.descendantFileCount.formatted()))
            var parts = [NeodiskFormatters.size(root.allocatedSize)]
            if let hidden = model.hiddenSpaceBytes {
                parts.append(L("%@ hidden", NeodiskFormatters.size(hidden)))
            }
            gtk_label_set_text(ptr(detailLabel), parts.joined(separator: " · "))
            swatch.rgb = nil
        }
        let warnings = model.warnings.count
        gtk_label_set_text(ptr(warningLabel), warnings == 0 ? "" : AppStrings.plural(warnings, one: "%@ file couldn\'t be read", other: "%@ files couldn\'t be read", warnings.formatted()))
        Widgets.setVisible(warningLabel, warnings > 0)
        if warnings > 0 {
            let paths = model.warnings.prefix(12).map { $0.path }
            let more = warnings > 12 ? "\n…" : ""
            gtk_widget_set_tooltip_text(ptr(warningLabel), paths.joined(separator: "\n") + more)
        }
    }
}
