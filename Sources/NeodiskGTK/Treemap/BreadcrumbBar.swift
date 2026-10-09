//
//  BreadcrumbBar.swift
//  NeodiskGTK
//
//  The path from the scan root down to the folder the visualizations are
//  drilled into; each crumb drills back out to its folder. Hidden at the
//  root, like the Mac's.
//

import CGtk
import Foundation
import NeodiskKit

@MainActor
final class BreadcrumbBar {
    let widget: GPtr
    private let model: AppModel
    private let crumbs: GPtr
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model
        crumbs = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2, classes: ["neodisk-breadcrumb"])
        let scroller = raw(gtk_scrolled_window_new())!
        gtk_scrolled_window_set_policy(ptr(scroller), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(ptr(scroller), ptr(crumbs))
        Widgets.setMargins(scroller, top: 4, bottom: 4, start: 8, end: 8)
        widget = scroller
        // Deep paths overflow: keep the end, the folder on screen, visible.
        let adjustment = gtk_scrolled_window_get_hadjustment(ptr(scroller))
        connect(raw(adjustment)!, "changed") {
            gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        }
        tokens.append(track { [unowned self] in self.rebuild() })
    }

    private func rebuild() {
        Widgets.removeAllChildren(of: crumbs)
        guard let store = model.store, let focusID = model.focusID else {
            Widgets.setVisible(widget, false)
            return
        }
        Widgets.setVisible(widget, true)
        let path = store.path(to: focusID)
        for (index, node) in path.enumerated() {
            if index > 0 {
                Widgets.append(crumbs, Widgets.label("›", classes: ["dim-label"]))
            }
            let title = index == 0
                ? (model.target.map { $0.id == "/" ? L("Computer") : $0.displayName } ?? node.name)
                : node.name
            let button = raw(gtk_button_new_with_label(title))!
            Widgets.addClasses(button, ["flat"])
            let isLast = index == path.count - 1
            gtk_widget_set_sensitive(ptr(button), gbool(!isLast))
            let nodeID = node.id
            connect(button, "clicked") { [unowned self] in
                self.model.focus(on: nodeID)
            }
            Widgets.append(crumbs, button)
        }
    }
}
