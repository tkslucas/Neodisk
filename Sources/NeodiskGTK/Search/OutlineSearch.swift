//
//  OutlineSearch.swift
//  NeodiskGTK
//
//  The file list's search field, as on the Mac: fuzzy search over every
//  name in the scan, off the main actor, through the shared search index
//  and matcher. While there's a query, the matches take the outline's place
//  (Ctrl+F focuses the field, Escape clears it). Filtering never navigates:
//  the map stays where it is until a result is picked, which selects it —
//  the treemap widens its focus to show it and the outline expands to it.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class OutlineSearch {
    /// The field over the list, then the outline or the matches under it.
    let widget: GPtr
    private let model: AppModel
    private let entry: GPtr
    private let entryBar: GPtr
    private let separator: GPtr
    private let stack: GPtr
    private let results: GPtr
    private let caption: GPtr
    private let debouncer = SearchDebouncer()
    private var resultIDs: [String] = []
    private var isSyncingSelection = false
    private var tokens: [ObservationToken] = []

    static let resultLimit = 200

    init(model: AppModel, outline: GPtr) {
        self.model = model
        entry = raw(gtk_search_entry_new())!
        gtk_search_entry_set_placeholder_text(ptr(entry), L("Search entire scan"))
        gtk_widget_set_hexpand(ptr(entry), gbool(true))
        entryBar = Widgets.box(GTK_ORIENTATION_HORIZONTAL, classes: ["neodisk-search-bar"], [entry])

        results = raw(gtk_list_box_new())!
        Widgets.addClasses(results, ["navigation-sidebar"])
        caption = Widgets.label("", classes: ["dim-label", "neodisk-caption"])
        Widgets.setMargins(caption, top: 4, bottom: 2, start: 12, end: 12)
        let resultsPage = Widgets.box(GTK_ORIENTATION_VERTICAL, [caption, Widgets.scrolled(results)])

        stack = raw(gtk_stack_new())!
        gtk_stack_add_named(ptr(stack), ptr(outline), "outline")
        gtk_stack_add_named(ptr(stack), ptr(resultsPage), "results")
        gtk_widget_set_vexpand(ptr(stack), gbool(true))

        separator = raw(gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))!
        widget = Widgets.box(GTK_ORIENTATION_VERTICAL, [entryBar, separator, stack])
        gtk_widget_set_size_request(ptr(widget), -1, 180)
        attach(self, to: widget, key: "neodisk-outline-search")

        connect(entry, "search-changed") { [unowned self] in self.schedule() }
        connect(entry, "activate") { [unowned self] in
            guard let first = self.resultIDs.first else { return }
            self.model.select(first)
        }
        connect(entry, "stop-search") { [unowned self] in self.clear() }
        connectPointer(results, "row-selected") { [unowned self] row in
            guard !self.isSyncingSelection, let row else { return }
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.resultIDs.indices.contains(index) else { return }
            self.model.select(self.resultIDs[index])
        }
        // Down from the field walks into the matches.
        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, _ in
            guard Int32(keyval) == GDK_KEY_Down, let first = gtk_list_box_get_row_at_index(ptr(self.results), 0) else {
                return false
            }
            gtk_widget_grab_focus(ptr(raw(first)))
            return true
        }
        gtk_widget_add_controller(ptr(entry), ptr(keys))

        tokens.append(track { [unowned self] in
            // A new location starts with an empty field.
            _ = self.model.target
            self.clear()
        })
        tokens.append(track { [unowned self] in
            // Searching needs a finished scan: the field waits for one (a
            // live scan streams partial trees), and a refresh of the same
            // location reruns the query on the new tree.
            let hasSnapshot = self.model.snapshot != nil
            Widgets.setVisible(self.entryBar, hasSnapshot)
            Widgets.setVisible(self.separator, hasSnapshot)
            self.schedule()
        })
        tokens.append(track { [unowned self] in
            self.syncSelection(self.model.selectedNodeID)
        })
    }

    /// Ctrl+F (the action is disabled until there's a scan to search).
    func focus() {
        gtk_widget_grab_focus(ptr(entry))
    }

    private var query: String {
        (string(from: gtk_editable_get_text(ptr(entry))) ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func clear() {
        if !query.isEmpty {
            gtk_editable_set_text(ptr(entry), "")
        }
        debouncer.cancel()
        show(ids: [], total: 0, query: "")
    }

    private func schedule() {
        let query = self.query
        guard !query.isEmpty, let snapshot = model.snapshot else {
            debouncer.cancel()
            show(ids: [], total: 0, query: "")
            model.searchDidEnd()
            return
        }
        model.searchDidBegin()
        gtk_stack_set_visible_child_name(ptr(stack), "results")
        let snapshotID = snapshot.id
        // The index builds on the first search (and a large scan's takes a
        // while); say so rather than show an empty list.
        if resultIDs.isEmpty {
            gtk_label_set_text(ptr(caption), L("Loading…"))
        }
        debouncer.schedule { [weak self] in
            guard let self else { return }
            let index = await self.model.searchIndex.index(for: snapshot)
            guard !Task.isCancelled, self.model.snapshot?.id == snapshotID else { return }
            let entries = index.entries
            let rootID = index.rootID
            let limit = Self.resultLimit
            let matches = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit) { $0.id != rootID }
            }.value
            guard !Task.isCancelled, self.model.snapshot?.id == snapshotID, self.query == query else { return }
            self.show(ids: matches.ids, total: matches.totalMatches, query: query)
        }
    }

    private func show(ids: [String], total: Int, query: String) {
        gtk_stack_set_visible_child_name(ptr(stack), query.isEmpty ? "outline" : "results")
        isSyncingSelection = true
        gtk_list_box_remove_all(ptr(results))
        isSyncingSelection = false
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
            gtk_widget_set_tooltip_text(ptr(row), node.path)
            gtk_list_box_append(ptr(results), ptr(row))
        }
        syncSelection(model.selectedNodeID)
    }

    /// Keeps the picked match highlighted, and drops the highlight when the
    /// selection moves elsewhere.
    private func syncSelection(_ nodeID: String?) {
        let currentIndex = gtk_list_box_get_selected_row(ptr(results)).map { Int(gtk_list_box_row_get_index($0)) }
        let wanted = nodeID.flatMap { id in resultIDs.firstIndex(of: id) }
        guard currentIndex != wanted else { return }
        isSyncingSelection = true
        if let wanted {
            gtk_list_box_select_row(ptr(results), gtk_list_box_get_row_at_index(ptr(results), Int32(wanted)))
        } else {
            gtk_list_box_unselect_all(ptr(results))
        }
        isSyncingSelection = false
    }
}
