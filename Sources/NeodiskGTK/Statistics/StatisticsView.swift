//
//  StatisticsView.swift
//  NeodiskGTK
//
//  The statistics pane on the right: Largest (the scan's biggest files),
//  Kinds (space by file category or type, the treemap's color legend), and
//  Age (space by last-modified bucket). The visible tab decides what map
//  color means, and picking a kind or age row lights just those cells —
//  the Mac's AnalysisPane behavior on the shared catalogs.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class StatisticsView {
    let widget: GPtr
    private let model: AppModel
    private let stack: GPtr
    private let largestList: GPtr
    private let kindsList: GPtr
    private let ageList: GPtr
    private let categoriesToggle: GPtr
    private let typesToggle: GPtr
    private let summaryLabel: GPtr
    private var largestIDs: [String] = []
    private var kindIDs: [String] = []
    private var ageBuckets: [AgeBucket] = []
    private var largestTask: Task<Void, Never>?
    private var largestGeneration = -1
    private var isSyncing = false
    private var tokens: [ObservationToken] = []

    nonisolated static let largestLimit = 150

    init(model: AppModel) {
        self.model = model

        stack = raw(adw_view_stack_new())!
        let switcher = raw(adw_view_switcher_new())!
        adw_view_switcher_set_stack(ptr(switcher), ptr(stack))
        adw_view_switcher_set_policy(ptr(switcher), ADW_VIEW_SWITCHER_POLICY_WIDE)
        Widgets.setMargins(switcher, top: 6, bottom: 6, start: 6, end: 6)

        summaryLabel = Widgets.label("", classes: ["dim-label", "neodisk-caption", "neodisk-numeric"], ellipsize: true)
        Widgets.setMargins(summaryLabel, bottom: 4, start: 12, end: 12)

        largestList = Self.makeList()
        kindsList = Self.makeList()
        ageList = Self.makeList()

        categoriesToggle = raw(gtk_toggle_button_new_with_label(L("Categories")))!
        typesToggle = raw(gtk_toggle_button_new_with_label(L("Types")))!
        gtk_toggle_button_set_group(ptr(typesToggle), ptr(categoriesToggle))
        let modeSwitch = Widgets.box(GTK_ORIENTATION_HORIZONTAL, classes: ["linked"], [categoriesToggle, typesToggle])
        gtk_widget_set_halign(ptr(modeSwitch), GTK_ALIGN_CENTER)
        Widgets.setMargins(modeSwitch, top: 4, bottom: 8)
        let kindsPage = Widgets.box(GTK_ORIENTATION_VERTICAL, [modeSwitch, Widgets.scrolled(kindsList)])

        Self.addPage(stack, Widgets.scrolled(largestList), name: AnalysisTab.largest.rawValue, title: AnalysisTab.largest.title, icon: "view-sort-descending-symbolic")
        Self.addPage(stack, kindsPage, name: AnalysisTab.kinds.rawValue, title: AnalysisTab.kinds.title, icon: "view-grid-symbolic")
        Self.addPage(stack, Widgets.scrolled(ageList), name: AnalysisTab.age.rawValue, title: AnalysisTab.age.title, icon: "document-open-recent-symbolic")

        widget = Widgets.box(GTK_ORIENTATION_VERTICAL, [switcher, summaryLabel, stack])
        gtk_widget_set_size_request(ptr(widget), 310, -1)
        attach(self, to: widget, key: "neodisk-statistics")

        connectNotify(stack, "visible-child-name") { [unowned self] in
            guard !self.isSyncing,
                  let name = string(from: adw_view_stack_get_visible_child_name(ptr(self.stack))),
                  let tab = AnalysisTab(rawValue: name) else { return }
            self.model.analysisTab = tab
        }
        connectPointer(largestList, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.largestIDs.indices.contains(index) else { return }
            self.model.select(self.largestIDs[index])
        }
        connectPointer(kindsList, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.kindIDs.indices.contains(index) else { return }
            let id = self.kindIDs[index]
            self.model.highlightedKindID = self.model.highlightedKindID == id ? nil : id
        }
        connectPointer(ageList, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.ageBuckets.indices.contains(index) else { return }
            let bucket = self.ageBuckets[index]
            self.model.highlightedAgeBucket = self.model.highlightedAgeBucket == bucket ? nil : bucket
        }
        connect(categoriesToggle, "toggled") { [unowned self] in
            guard !self.isSyncing, gtk_toggle_button_get_active(ptr(self.categoriesToggle)) != 0 else { return }
            self.setKindMode(.categories)
        }
        connect(typesToggle, "toggled") { [unowned self] in
            guard !self.isSyncing, gtk_toggle_button_get_active(ptr(self.typesToggle)) != 0 else { return }
            self.setKindMode(.types)
        }

        tokens.append(track { [unowned self] in
            let tab = self.model.analysisTab
            self.isSyncing = true
            adw_view_stack_set_visible_child_name(ptr(self.stack), tab.rawValue)
            let mode = self.model.preferences.kindMode
            gtk_toggle_button_set_active(ptr(mode == .categories ? self.categoriesToggle : self.typesToggle), gbool(true))
            self.isSyncing = false
        })
        tokens.append(track { [unowned self] in self.reloadKinds() })
        tokens.append(track { [unowned self] in self.reloadAges() })
        tokens.append(track { [unowned self] in
            _ = self.model.store.map { _ in self.model.storeGeneration }
            _ = self.model.phase
            self.reloadLargest()
        })
        tokens.append(track { [unowned self] in
            guard let store = self.model.store else {
                gtk_label_set_text(ptr(self.summaryLabel), "")
                return
            }
            let root = store.root
            gtk_label_set_text(ptr(self.summaryLabel), L(
                "%@ in %@ files",
                NeodiskFormatters.size(root.allocatedSize),
                root.descendantFileCount.formatted()
            ))
        })
    }

    private static func makeList() -> GPtr {
        let list = raw(gtk_list_box_new())!
        Widgets.addClasses(list, ["navigation-sidebar"])
        gtk_list_box_set_selection_mode(ptr(list), GTK_SELECTION_SINGLE)
        return list
    }

    private static func addPage(_ stack: GPtr, _ child: GPtr, name: String, title: String, icon: String) {
        adw_view_stack_add_titled_with_icon(ptr(stack), ptr(child), name, title, icon)
    }

    private func setKindMode(_ mode: FileKindDisplayMode) {
        guard model.preferences.kindMode != mode else { return }
        model.preferences.kindMode = mode
        model.highlightedKindID = nil
        model.refreshCatalogs()
    }

    // MARK: - Kinds

    private func reloadKinds() {
        let catalog = model.catalog
        let highlighted = model.highlightedKindID
        let total = max(1, catalog.stats.reduce(Int64(0)) { $0 + $1.totalAllocatedSize })
        gtk_list_box_remove_all(ptr(kindsList))
        kindIDs = catalog.stats.map(\.kind.id)
        for stat in catalog.stats {
            let row = legendRow(
                rgb: stat.rgb,
                title: L(stat.kind.displayName),
                detail: L("%@ files", stat.fileCount.formatted()),
                size: stat.totalAllocatedSize,
                fraction: Double(stat.totalAllocatedSize) / Double(total)
            )
            gtk_list_box_append(ptr(kindsList), ptr(row))
            if stat.kind.id == highlighted {
                gtk_list_box_select_row(ptr(kindsList), ptr(row))
            }
        }
    }

    // MARK: - Age

    private func reloadAges() {
        let catalog = model.ageCatalog
        let palette = model.palette
        let highlighted = model.highlightedAgeBucket
        let total = max(1, catalog.stats.reduce(Int64(0)) { $0 + $1.totalAllocatedSize })
        gtk_list_box_remove_all(ptr(ageList))
        ageBuckets = catalog.stats.map(\.bucket)
        for stat in catalog.stats {
            let row = legendRow(
                rgb: palette.ageRGB(stat.bucket),
                title: L(stat.bucket.displayName),
                detail: L("%@ files", stat.fileCount.formatted()),
                size: stat.totalAllocatedSize,
                fraction: Double(stat.totalAllocatedSize) / Double(total)
            )
            gtk_list_box_append(ptr(ageList), ptr(row))
            if stat.bucket == highlighted {
                gtk_list_box_select_row(ptr(ageList), ptr(row))
            }
        }
    }

    /// Swatch, name, file count, and size over a thin share bar.
    private func legendRow(rgb: SIMD3<Float>, title: String, detail: String, size: Int64, fraction: Double) -> GPtr {
        let swatch = ColorSwatch(rgb: rgb)
        let name = Widgets.label(title, ellipsize: true)
        gtk_widget_set_hexpand(ptr(name), gbool(true))
        let sizeLabel = Widgets.label(NeodiskFormatters.size(size), xalign: 1, classes: ["neodisk-numeric"])
        let top = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, [swatch.widget, name, sizeLabel])
        let bar = raw(gtk_level_bar_new())!
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_LOW)
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_HIGH)
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_FULL)
        gtk_level_bar_add_offset_value(ptr(bar), "neodisk-used", 1.0)
        gtk_level_bar_set_value(ptr(bar), min(1, max(0, fraction)))
        Widgets.addClasses(bar, ["neodisk-capacity"])
        let detailLabel = Widgets.label(
            "\(detail) · \(fraction.formatted(.percent.precision(.fractionLength(1))))",
            classes: ["dim-label", "neodisk-caption", "neodisk-numeric"]
        )
        let content = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 3, classes: ["neodisk-stats-row"], [top, bar, detailLabel])
        let row = raw(gtk_list_box_row_new())!
        gtk_list_box_row_set_child(ptr(row), ptr(content))
        attach(swatch, to: row, key: "neodisk-swatch")
        return row
    }

    // MARK: - Largest

    private func reloadLargest() {
        guard let store = model.store else {
            largestTask?.cancel()
            largestIDs = []
            gtk_list_box_remove_all(ptr(largestList))
            largestGeneration = -1
            return
        }
        // Partial trees change every moment; list the finished one.
        guard model.phase != .scanning, model.storeGeneration != largestGeneration else { return }
        largestGeneration = model.storeGeneration
        largestTask?.cancel()
        largestTask = Task { [weak self] in
            let top = await Task.detached(priority: .utility) { () -> [FileNodeRecord] in
                Self.largestFiles(in: store, limit: Self.largestLimit)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.showLargest(top, rootSize: store.root.allocatedSize)
        }
    }

    /// The biggest countable items (files, packages, summarized folders),
    /// largest first, keeping a bounded sorted buffer instead of sorting
    /// the whole tree.
    nonisolated static func largestFiles(in store: FileTreeStore, limit: Int) -> [FileNodeRecord] {
        var top: [FileNodeRecord] = []
        top.reserveCapacity(limit + 1)
        var floor: Int64 = 0
        for node in store.allNodes {
            if Task.isCancelled { return [] }
            guard node.allocatedSize > floor || top.count < limit,
                  !node.isSynthetic,
                  FileKindClassifier.isKindCountable(node, in: store) else { continue }
            let index = top.firstIndex { $0.allocatedSize < node.allocatedSize } ?? top.endIndex
            top.insert(node, at: index)
            if top.count > limit {
                top.removeLast()
            }
            if top.count == limit {
                floor = top[top.count - 1].allocatedSize
            }
        }
        return top
    }

    private func showLargest(_ nodes: [FileNodeRecord], rootSize: Int64) {
        gtk_list_box_remove_all(ptr(largestList))
        largestIDs = nodes.map(\.id)
        let rootPath = model.store?.root.path ?? ""
        for node in nodes {
            let icon = Widgets.image(OutlineView.iconName(for: node))
            let name = Widgets.label(node.name, ellipsize: true)
            gtk_widget_set_hexpand(ptr(name), gbool(true))
            let size = Widgets.label(NeodiskFormatters.size(node.allocatedSize), xalign: 1, classes: ["neodisk-numeric"])
            let top = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, [icon, name, size])
            var location = (node.path as NSString).deletingLastPathComponent
            if location.hasPrefix(rootPath), rootPath != "/" {
                location = String(location.dropFirst(rootPath.count))
                if location.isEmpty { location = "/" }
            }
            let path = Widgets.label(DisplayFormatters.displayPath(location), classes: ["dim-label", "neodisk-caption"], ellipsize: true)
            Widgets.setMargins(path, start: 24)
            let content = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 2, classes: ["neodisk-stats-row"], [top, path])
            let row = raw(gtk_list_box_row_new())!
            gtk_list_box_row_set_child(ptr(row), ptr(content))
            gtk_widget_set_tooltip_text(ptr(row), node.path)
            gtk_list_box_append(ptr(largestList), ptr(row))
        }
    }
}
