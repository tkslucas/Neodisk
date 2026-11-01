// The file actions of a plain list of items (Largest, search matches), in step with the outline and the maps:
// right-click opens the item's menu, Delete offers to move it to the Trash.

import CGtk
import Foundation

@MainActor
final class ItemListActions {
    private let list: GPtr
    private let model: AppModel
    private let itemID: @MainActor (Int) -> String?
    private var menu: GPtr?

    /// `itemID`: the item a row index stands for.
    init(list: GPtr, model: AppModel, itemID: @escaping @MainActor (Int) -> String?) {
        self.list = list
        self.model = model
        self.itemID = itemID

        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self] _, x, y in
            guard let row = gtk_list_box_get_row_at_y(ptr(self.list), Int32(y)),
                  let id = self.itemID(Int(gtk_list_box_row_get_index(row))) else { return }
            // The menu acts on the selection: the row under the pointer becomes it.
            gtk_list_box_select_row(ptr(self.list), row)
            self.model.select(id)
            Widgets.popupMenu(&self.menu, sections: [
                [(L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"), (L("Copy Path"), "win.copy-path")],
                [(L("Move to Trash…"), "win.move-to-trash")],
            ], on: self.list, at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(list), ptr(click))

        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, state in
            MainWindow.handleTrashKey(keyval, state: state, from: self.list)
        }
        gtk_widget_add_controller(ptr(list), ptr(keys))
    }
}
