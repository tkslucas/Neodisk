//
//  SearchPopover.swift
//  NeodiskGTK
//
//  Ctrl+F: fuzzy search over every name in the scan, off the main actor,
//  through the shared search index and matcher the Mac uses. Picking a
//  result selects it; the treemap widens its focus to show it and the
//  outline expands down to it.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class SearchPopover {
    private let model: AppModel
    private let popover: GPtr
    private let entry: GPtr
    private let results: GPtr
    private let caption: GPtr
    private let indexService = SearchIndexService()
    private let debouncer = SearchDebouncer()
    private var resultIDs: [String] = []

    static let resultLimit = 60

    init(model: AppModel, parent: GPtr) {
        self.model = model
        entry = raw(gtk_search_entry_new())!
        gtk_search_entry_set_placeholder_text(ptr(entry), L("Search the whole scan"))
        results = raw(gtk_list_box_new())!
        Widgets.addClasses(results, ["navigation-sidebar"])
        caption = Widgets.label("", classes: ["dim-label", "neodisk-caption"])
        let scrolled = Widgets.scrolled(results)
        gtk_scrolled_window_set_min_content_height(ptr(scrolled), 360)
        gtk_scrolled_window_set_min_content_width(ptr(scrolled), 460)
        let content = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 6, [entry, caption, scrolled])
        Widgets.setMargins(content, all: 6)

        popover = raw(gtk_popover_new())!
        gtk_popover_set_child(ptr(popover), ptr(content))
        gtk_widget_set_parent(ptr(popover), ptr(parent))
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)

        connect(entry, "search-changed") { [unowned self] in self.schedule() }
        connect(entry, "activate") { [unowned self] in
            guard let first = self.resultIDs.first else { return }
            self.choose(first)
        }
        connect(entry, "stop-search") { [unowned self] in
            gtk_popover_popdown(ptr(self.popover))
        }
        connectPointer(results, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.resultIDs.indices.contains(index) else { return }
            self.choose(self.resultIDs[index])
        }
        // Down from the entry walks into the results.
        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, _ in
            guard Int32(keyval) == GDK_KEY_Down, let first = gtk_list_box_get_row_at_index(ptr(self.results), 0) else {
                return false
            }
            gtk_widget_grab_focus(ptr(raw(first)))
            return true
        }
        gtk_widget_add_controller(ptr(entry), ptr(keys))
    }

    func present() {
        gtk_popover_popup(ptr(popover))
        gtk_widget_grab_focus(ptr(entry))
        schedule()
    }

    private func choose(_ id: String) {
        model.select(id)
        gtk_popover_popdown(ptr(popover))
    }

    private func schedule() {
        let query = (string(from: gtk_editable_get_text(ptr(entry))) ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let snapshot = model.snapshot else {
            debouncer.cancel()
            show(ids: [], total: 0, query: query)
            return
        }
        let snapshotID = snapshot.id
        debouncer.schedule { [weak self] in
            guard let self else { return }
            let index = await self.indexService.index(for: snapshot)
            guard !Task.isCancelled, self.model.snapshot?.id == snapshotID else { return }
            let entries = index.entries
            let rootID = index.rootID
            let limit = Self.resultLimit
            let matches = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit) { $0.id != rootID }
            }.value
            guard !Task.isCancelled, self.model.snapshot?.id == snapshotID else { return }
            self.show(ids: matches.ids, total: matches.totalMatches, query: query)
        }
    }

    private func show(ids: [String], total: Int, query: String) {
        gtk_list_box_remove_all(ptr(results))
        resultIDs = ids
        if query.isEmpty {
            gtk_label_set_text(ptr(caption), "")
        } else if total == 0 {
            gtk_label_set_text(ptr(caption), L("No matches"))
        } else {
            gtk_label_set_text(ptr(caption), total > ids.count
                ? L("Top %lld of %@ matches", Int64(ids.count), total.formatted())
                : L("%@ matches", total.formatted()))
        }
        guard let store = model.store else { return }
        for id in ids {
            guard let node = store.node(id: id) else { continue }
            let icon = Widgets.image(OutlineView.iconName(for: node))
            let name = Widgets.label(node.name, ellipsize: true)
            gtk_widget_set_hexpand(ptr(name), gbool(true))
            let size = Widgets.label(NeodiskFormatters.size(node.allocatedSize), xalign: 1, classes: ["neodisk-numeric", "dim-label"])
            let top = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8, [icon, name, size])
            let location = DisplayFormatters.displayPath((node.path as NSString).deletingLastPathComponent)
            let path = Widgets.label(location, classes: ["dim-label", "neodisk-caption"], ellipsize: true)
            Widgets.setMargins(path, start: 24)
            let content = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 2, classes: ["neodisk-stats-row"], [top, path])
            let row = raw(gtk_list_box_row_new())!
            gtk_list_box_row_set_child(ptr(row), ptr(content))
            gtk_list_box_append(ptr(results), ptr(row))
        }
    }
}
