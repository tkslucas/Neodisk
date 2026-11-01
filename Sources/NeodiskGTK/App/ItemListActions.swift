// A plain list of items (Largest, search matches), in step with the outline and the maps: several rows can be
// selected (Ctrl- and Shift-click, Ctrl+A), right-click opens the menu for the selection, Delete offers to move
// it to the Trash.

import CGtk
import Foundation

@MainActor
final class ItemListActions {
    private let list: GPtr
    private let model: AppModel
    private let itemID: @MainActor (Int) -> String?
    private let itemCount: @MainActor () -> Int
    private var menu: GPtr?
    private var isSyncing = false
    /// The input that changed the rows held Ctrl or Shift: the items the list doesn't show stay selected.
    private var isExtending = false

    /// `itemID`: the item a row index stands for; `itemCount`: how many rows there are.
    init(
        list: GPtr, model: AppModel,
        itemCount: @escaping @MainActor () -> Int, itemID: @escaping @MainActor (Int) -> String?
    ) {
        self.list = list
        self.model = model
        self.itemID = itemID
        self.itemCount = itemCount
        gtk_list_box_set_selection_mode(ptr(list), GTK_SELECTION_MULTIPLE)

        connect(list, "selected-rows-changed") { [unowned self] in self.rowsDidChange() }

        // Seen before the list acts on them, so the change knows whether it extends the selection.
        let press = raw(gtk_gesture_click_new())!
        gtk_event_controller_set_propagation_phase(ptr(press), GTK_PHASE_CAPTURE)
        connectPress(press, "pressed") { [unowned self] _, _, _ in
            self.isExtending = Self.extends(gtk_event_controller_get_current_event_state(ptr(press)).rawValue)
        }
        gtk_widget_add_controller(ptr(list), ptr(press))

        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self] _, x, y in
            guard let row = gtk_list_box_get_row_at_y(ptr(self.list), Int32(y)),
                  let id = self.itemID(Int(gtk_list_box_row_get_index(row))) else { return }
            // The menu acts on the selection: a row outside it becomes it (GNOME's rule).
            if !self.model.selection.contains(id) { self.model.select(id) }
            let several = self.model.selection.isMultiple
            Widgets.popupMenu(&self.menu, sections: [
                [
                    (L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"),
                    (several ? L("Copy Paths") : L("Copy Path"), "win.copy-path"),
                ],
                [(L("Move to Trash…"), "win.move-to-trash")],
            ], on: self.list, at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(list), ptr(click))

        let keys = raw(gtk_event_controller_key_new())!
        gtk_event_controller_set_propagation_phase(ptr(keys), GTK_PHASE_CAPTURE)
        connectKey(keys) { [unowned self] keyval, state in
            // Ctrl+A picks exactly this list's rows, so Delete after it never takes another view's pick.
            self.isExtending = Self.extends(state) && !TreemapView.isSelectAll(keyval, state: state)
            return MainWindow.handleTrashKey(keyval, state: state, from: self.list)
        }
        gtk_widget_add_controller(ptr(list), ptr(keys))
    }

    private static func extends(_ state: UInt32) -> Bool {
        state & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue) != 0
    }

    /// Rows removed or rebuilt in `body` aren't the user's pick.
    func whileRebuilding(_ body: () -> Void) {
        isSyncing = true
        body()
        isSyncing = false
    }

    /// Highlights the listed selected items, and nothing else. Call after rebuilding the rows too.
    func sync() {
        isSyncing = true
        defer { isSyncing = false }
        let selection = model.selection
        for index in 0..<itemCount() {
            guard let row = gtk_list_box_get_row_at_index(ptr(list), Int32(index)) else { continue }
            let wanted = itemID(index).map(selection.contains) ?? false
            guard (gtk_list_box_row_is_selected(row) != 0) != wanted else { continue }
            if wanted {
                gtk_list_box_select_row(ptr(list), row)
            } else {
                gtk_list_box_unselect_row(ptr(list), row)
            }
        }
    }

    private func rowsDidChange() {
        guard !isSyncing else { return }
        var picked: [String] = []
        var shown = Set<String>()
        for index in 0..<itemCount() {
            guard let id = itemID(index) else { continue }
            shown.insert(id)
            if let row = gtk_list_box_get_row_at_index(ptr(list), Int32(index)), gtk_list_box_row_is_selected(row) != 0 {
                picked.append(id)
            }
        }
        // Rebuilding the rows unselects them all; that's not the user's pick.
        guard !picked.isEmpty || isExtending else { return }
        model.select(fromList: picked, extending: isExtending) { shown.contains($0) }
    }
}
