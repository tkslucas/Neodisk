// Small constructors for the widgets the views compose, so layout code
// reads as a description of the layout rather than of the C API.

import CGtk
import Foundation

@MainActor
enum Widgets {
    static func label(
        _ text: String = "",
        xalign: Float = 0,
        classes: [String] = [],
        ellipsize: Bool = false,
        wrap: Bool = false
    ) -> GPtr {
        let label = raw(gtk_label_new(text))!
        gtk_label_set_xalign(ptr(label), xalign)
        if ellipsize {
            gtk_label_set_ellipsize(ptr(label), PANGO_ELLIPSIZE_MIDDLE)
        }
        if wrap {
            gtk_label_set_wrap(ptr(label), gbool(true))
        }
        addClasses(label, classes)
        return label
    }

    static func box(
        _ orientation: GtkOrientation,
        spacing: Int = 0,
        classes: [String] = [],
        _ children: [GPtr] = []
    ) -> GPtr {
        let box = raw(gtk_box_new(orientation, Int32(spacing)))!
        for child in children {
            gtk_box_append(ptr(box), ptr(child))
        }
        addClasses(box, classes)
        return box
    }

    static func append(_ box: GPtr, _ child: GPtr) {
        gtk_box_append(ptr(box), ptr(child))
    }

    static func iconButton(_ iconName: String, tooltip: String, action: String? = nil) -> GPtr {
        let button = raw(gtk_button_new_from_icon_name(iconName))!
        gtk_widget_set_tooltip_text(ptr(button), tooltip)
        if let action {
            gtk_actionable_set_action_name(ptr(button), action)
        }
        return button
    }

    static func image(_ iconName: String, pixelSize: Int? = nil, classes: [String] = []) -> GPtr {
        let image = raw(gtk_image_new_from_icon_name(iconName))!
        if let pixelSize {
            gtk_image_set_pixel_size(ptr(image), Int32(pixelSize))
        }
        addClasses(image, classes)
        return image
    }

    static func scrolled(_ child: GPtr, horizontalPolicy: GtkPolicyType = GTK_POLICY_NEVER) -> GPtr {
        let scrolled = raw(gtk_scrolled_window_new())!
        gtk_scrolled_window_set_policy(ptr(scrolled), horizontalPolicy, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(ptr(scrolled), ptr(child))
        gtk_widget_set_vexpand(ptr(scrolled), gbool(true))
        return scrolled
    }

    static func addClasses(_ widget: GPtr, _ classes: [String]) {
        for name in classes {
            gtk_widget_add_css_class(ptr(widget), name)
        }
    }

    static func setClass(_ widget: GPtr, _ name: String, _ enabled: Bool) {
        if enabled {
            gtk_widget_add_css_class(ptr(widget), name)
        } else {
            gtk_widget_remove_css_class(ptr(widget), name)
        }
    }

    static func setVisible(_ widget: GPtr?, _ visible: Bool) {
        gtk_widget_set_visible(ptr(widget), gbool(visible))
    }

    static func setMargins(_ widget: GPtr, top: Int = 0, bottom: Int = 0, start: Int = 0, end: Int = 0) {
        gtk_widget_set_margin_top(ptr(widget), Int32(top))
        gtk_widget_set_margin_bottom(ptr(widget), Int32(bottom))
        gtk_widget_set_margin_start(ptr(widget), Int32(start))
        gtk_widget_set_margin_end(ptr(widget), Int32(end))
    }

    static func setMargins(_ widget: GPtr, all: Int) {
        setMargins(widget, top: all, bottom: all, start: all, end: all)
    }

    static func removeAllChildren(of box: GPtr) {
        while let child = gtk_widget_get_first_child(ptr(box)) {
            gtk_box_remove(ptr(box), child)
        }
    }

    /// The first widget of `type` under `root`, depth first.
    static func firstDescendant(of root: GPtr, ofType type: GType) -> GPtr? {
        var child = gtk_widget_get_first_child(ptr(root))
        while let current = child {
            if g_type_check_instance_is_a(ptr(raw(current)), type) != 0 { return raw(current) }
            if let found = firstDescendant(of: raw(current)!, ofType: type) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    /// Removes a list box's rows. Not `gtk_list_box_remove_all`: it removes every child, and a row menu's popover
    /// parented to the list isn't a row, so it would loop on it forever.
    static func removeAllRows(of list: GPtr) {
        while let row = gtk_list_box_get_row_at_index(ptr(list), 0) {
            gtk_list_box_remove(ptr(list), ptr(raw(row)))
        }
    }

    /// Created into `cache` on first use. The tooltip under the pointer is off while open, or GTK draws a showing
    /// one over the menu.
    static func popupMenu(_ cache: inout GPtr?, sections: [[(String, String)]], on parent: GPtr, at point: CGPoint) {
        popupMenu(&cache, model: menu(sections), on: parent, at: point)
    }

    static func popupMenu(_ cache: inout GPtr?, model: GObjectRef, on parent: GPtr, at point: CGPoint) {
        if let cache {
            // Labels may follow the selection ("Copy Paths" for several): the items are rebuilt, the popover kept.
            gtk_popover_menu_set_menu_model(ptr(cache), ptr(model.pointer))
        } else {
            let popover = raw(gtk_popover_menu_new_from_model(ptr(model.pointer)))!
            gtk_widget_set_parent(ptr(popover), ptr(parent))
            gtk_popover_set_has_arrow(ptr(popover), gbool(false))
            connect(popover, "closed") {
                if let owner = suppressedTooltips.removeValue(forKey: popover) {
                    gtk_widget_set_has_tooltip(ptr(owner), gbool(true))
                }
            }
            cache = popover
        }
        if let popover = cache, suppressedTooltips[popover] == nil, let owner = tooltipOwner(in: parent, at: point) {
            suppressedTooltips[popover] = owner
            gtk_widget_set_has_tooltip(ptr(owner), gbool(false))
            gtk_widget_trigger_tooltip_query(ptr(owner))
        }
        var rect = GdkRectangle(x: Int32(point.x), y: Int32(point.y), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(cache), &rect)
        gtk_popover_popup(ptr(cache))
    }

    /// Popovers to the widget whose tooltip they turned off.
    private static var suppressedTooltips: [GPtr: GPtr] = [:]

    /// The widget at `point` (in `parent`'s coordinates), or its nearest ancestor up to `parent`, that has a tooltip.
    private static func tooltipOwner(in parent: GPtr, at point: CGPoint) -> GPtr? {
        var widget = raw(gtk_widget_pick(ptr(parent), point.x, point.y, GTK_PICK_DEFAULT))
        while let current = widget {
            if gtk_widget_get_has_tooltip(ptr(current)) != 0 { return current }
            if current == parent { return nil }
            widget = raw(gtk_widget_get_parent(ptr(current)))
        }
        return nil
    }

    /// Extra menu item attributes by action: Delete shows as an accelerator (the focused view handles the key),
    /// and Move to Trash hides when its action leaves the window (turned off in Preferences).
    private static let itemAttributes: [String: [(String, String)]] = [
        "win.move-to-trash": [("accel", "Delete"), ("hidden-when", "action-missing")],
    ]

    static func menu(_ sections: [[(String, String)]]) -> GObjectRef {
        menu(sections: sections.map(section))
    }

    static func menu(sections: [GObjectRef]) -> GObjectRef {
        let menu = raw(g_menu_new())!
        for section in sections {
            g_menu_append_section(ptr(menu), nil, ptr(section.pointer))
        }
        return GObjectRef(adopting: menu)
    }

    /// A menu section; append submenus to it with `g_menu_append_submenu`.
    static func section(_ items: [(String, String)]) -> GObjectRef {
        let section = raw(g_menu_new())!
        for (label, action) in items {
            let item = g_menu_item_new(label, action)
            for (name, value) in itemAttributes[action] ?? [] {
                g_menu_item_set_attribute_value(item, name, g_variant_new_string(value))
            }
            g_menu_append_item(ptr(section), item)
            g_object_unref(raw(item))
        }
        return GObjectRef(adopting: section)
    }
}

/// App style sheet: the handful of rules libadwaita's stylesheet doesn't
/// already cover.
@MainActor
enum Styles {
    static let css = """
    .neodisk-numeric { font-feature-settings: "tnum"; }
    .neodisk-caption { font-size: smaller; }
    .neodisk-statusbar { padding: 4px 12px; border-top: 1px solid alpha(currentColor, 0.12); }
    .neodisk-sidebar-row { padding: 6px 4px; }
    .neodisk-sidebar-section > box > title { padding: 12px 12px 6px 12px; }
    .neodisk-capacity trough { min-height: 4px; }
    .neodisk-capacity block { min-height: 4px; }
    .neodisk-progress-caption { padding: 2px 12px 6px 12px; }
    .neodisk-stats-row { padding: 4px 8px; }
    .neodisk-swatch { border-radius: 3px; min-width: 10px; min-height: 10px; }
    .neodisk-breadcrumb button { padding: 2px 6px; min-height: 0; }
    .neodisk-search-bar { padding: 6px 8px; }
    levelbar.neodisk-capacity block.neodisk-used { background-color: @accent_bg_color; }
    popover.neodisk-bubble > contents { padding: 4px 9px; }
    """

    static func install() {
        guard let display = gdk_display_get_default() else { return }
        // The app's own symbolic icons (treemap, sunburst) join the theme.
        if let icons = DataDirectory.url(for: .icons) {
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(display), icons.path)
        }
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            display,
            OpaquePointer(provider),
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
        g_object_unref(provider)
    }
}
