//
//  StatusBar.swift
//  NeodiskGTK
//
//  The strip along the bottom of the workspace: what the pointer is over
//  (or what is selected), with its size and share of the scan, and scan
//  warnings — the same readout the macOS status bar gives.
//

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
        tokens.append(track { [unowned self] in self.update() })
    }

    private func update() {
        let node = model.hoveredNode ?? model.selectedNode
        guard let store = model.store else {
            Widgets.setVisible(widget, false)
            return
        }
        Widgets.setVisible(widget, true)
        if let node {
            gtk_label_set_text(ptr(nameLabel), node.name)
            var parts = [NeodiskFormatters.size(node.allocatedSize)]
            if let share = NeodiskFormatters.percentage(part: node.allocatedSize, total: store.root.allocatedSize) {
                parts.append(L("%@ of scan", share))
            }
            if node.isDirectory {
                parts.append(L("%@ files", node.descendantFileCount.formatted()))
            }
            parts.append(DisplayFormatters.displayPath(node.path))
            gtk_label_set_text(ptr(detailLabel), parts.joined(separator: " · "))
            swatch.rgb = model.catalog.rgb(for: node)
        } else {
            let root = store.root
            gtk_label_set_text(ptr(nameLabel), L("%@ items", root.descendantFileCount.formatted()))
            var parts = [NeodiskFormatters.size(root.allocatedSize)]
            if let hidden = model.hiddenSpaceBytes {
                parts.append(L("%@ hidden", NeodiskFormatters.size(hidden)))
            }
            gtk_label_set_text(ptr(detailLabel), parts.joined(separator: " · "))
            swatch.rgb = nil
        }
        let warnings = model.warnings.count
        gtk_label_set_text(ptr(warningLabel), warnings == 0 ? "" : L("%@ files couldn't be read", warnings.formatted()))
        Widgets.setVisible(warningLabel, warnings > 0)
        if warnings > 0 {
            let paths = model.warnings.prefix(12).map { DisplayFormatters.displayPath($0.path) }
            let more = warnings > 12 ? "\n…" : ""
            gtk_widget_set_tooltip_text(ptr(warningLabel), paths.joined(separator: "\n") + more)
        }
    }
}
