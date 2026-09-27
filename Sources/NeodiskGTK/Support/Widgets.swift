//
//  Widgets.swift
//  NeodiskGTK
//
//  Small constructors for the widgets the views compose, so layout code
//  reads as a description of the layout rather than of the C API.
//

import CGtk

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

    /// A menu model from sections of (label, detailed action) items.
    static func menu(_ sections: [[(String, String)]]) -> GObjectRef {
        let menu = raw(g_menu_new())!
        for items in sections {
            let section = g_menu_new()
            for (label, action) in items {
                g_menu_append(section, label, action)
            }
            g_menu_append_section(ptr(menu), nil, ptr(raw(section)))
            g_object_unref(raw(section))
        }
        return GObjectRef(adopting: menu)
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
    .neodisk-capacity trough { min-height: 4px; }
    .neodisk-capacity block { min-height: 4px; }
    .neodisk-progress-caption { padding: 2px 12px 6px 12px; }
    .neodisk-stats-row { padding: 4px 8px; }
    .neodisk-swatch { border-radius: 3px; min-width: 10px; min-height: 10px; }
    .neodisk-breadcrumb button { padding: 2px 6px; min-height: 0; }
    levelbar.neodisk-capacity block.neodisk-used { background-color: @accent_bg_color; }
    levelbar.neodisk-capacity block.neodisk-nearly-full { background-color: @warning_bg_color; }
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
