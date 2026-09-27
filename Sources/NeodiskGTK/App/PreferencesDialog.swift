//
//  PreferencesDialog.swift
//  NeodiskGTK
//
//  Settings, as an AdwPreferencesDialog: appearance, what scans include,
//  how the map is drawn, and the snapshot cache. Rows write straight to
//  `Preferences`; the views observe it, so changes apply live.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit

@MainActor
enum PreferencesDialog {
    static func present(model: AppModel, from window: GPtr?) {
        let preferences = model.preferences
        let dialog = raw(adw_preferences_dialog_new())!

        // Appearance and visualization.
        let viewPage = page(L("View"), icon: "preferences-desktop-appearance-symbolic")
        let appearance = group(L("Appearance"))
        let schemes = Preferences.ColorScheme.allCases
        addCombo(to: appearance, title: L("Style"), items: [L("Follow System"), L("Light"), L("Dark")],
                 selected: schemes.firstIndex(of: preferences.colorScheme) ?? 0) { index in
            preferences.colorScheme = schemes[index]
        }
        let palettes = VizPalette.all
        addCombo(to: appearance, title: L("Color Palette"), items: palettes.map { L($0.title) },
                 selected: palettes.firstIndex { $0.id == preferences.paletteID } ?? 0) { index in
            preferences.paletteID = palettes[index].id
            model.paletteDidChange()
        }
        adw_preferences_page_add(ptr(viewPage), ptr(appearance))

        let treemap = group(L("Treemap"))
        addSwitch(to: treemap, title: L("Show Free Space"),
                  subtitle: L("Draw a volume's free space as a block of its own"),
                  isOn: preferences.showFreeSpace) { preferences.showFreeSpace = $0 }
        adw_preferences_page_add(ptr(viewPage), ptr(treemap))
        adw_preferences_dialog_add(ptr(dialog), ptr(viewPage))

        // Scanning.
        let scanPage = page(L("Scanning"), icon: "drive-harddisk-symbolic")
        let scanning = group(L("Scans"), description: L("Changes apply from the next scan."))
        addSwitch(to: scanning, title: L("Include Hidden Files"),
                  subtitle: L("Dot files and folders, like ~/.cache and ~/.local"),
                  isOn: preferences.includeHiddenFiles) { preferences.includeHiddenFiles = $0 }
        addSwitch(to: scanning, title: L("Summarize Huge Folders"),
                  subtitle: L("Count folders with very many small files as one item, for faster scans"),
                  isOn: preferences.autoSummarizeDirectories) { preferences.autoSummarizeDirectories = $0 }
        adw_preferences_page_add(ptr(scanPage), ptr(scanning))

        let storage = group(L("Saved Scans"), description: L("Finished scans are kept so locations reopen instantly and changes can be compared."))
        let cacheRow = raw(adw_action_row_new())!
        adw_preferences_row_set_title(ptr(cacheRow), L("Cached Scans"))
        adw_action_row_set_subtitle(ptr(cacheRow), L("Calculating…"))
        let clearButton = raw(gtk_button_new_with_label(L("Clear")))!
        Widgets.addClasses(clearButton, ["destructive-action"])
        gtk_widget_set_valign(ptr(clearButton), GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(cacheRow), ptr(clearButton))
        adw_preferences_group_add(ptr(storage), ptr(cacheRow))
        adw_preferences_page_add(ptr(scanPage), ptr(storage))
        adw_preferences_dialog_add(ptr(dialog), ptr(scanPage))

        let cache = model.snapshotCache
        Task { @MainActor in
            let bytes = await cache.totalSizeOnDisk()
            adw_action_row_set_subtitle(ptr(cacheRow), NeodiskFormatters.size(bytes))
        }
        connect(clearButton, "clicked") {
            Task { @MainActor in
                await cache.removeAll()
                await model.refreshCachedScans(keeping: [])
                adw_action_row_set_subtitle(ptr(cacheRow), NeodiskFormatters.size(await cache.totalSizeOnDisk()))
            }
        }

        adw_dialog_present(ptr(dialog), ptr(window))
    }

    private static func page(_ title: String, icon: String) -> GPtr {
        let page = raw(adw_preferences_page_new())!
        adw_preferences_page_set_title(ptr(page), title)
        adw_preferences_page_set_icon_name(ptr(page), icon)
        return page
    }

    private static func group(_ title: String, description: String? = nil) -> GPtr {
        let group = raw(adw_preferences_group_new())!
        adw_preferences_group_set_title(ptr(group), title)
        if let description {
            adw_preferences_group_set_description(ptr(group), description)
        }
        return group
    }

    private static func addSwitch(
        to group: GPtr,
        title: String,
        subtitle: String? = nil,
        isOn: Bool,
        _ changed: @escaping @MainActor (Bool) -> Void
    ) {
        let row = raw(adw_switch_row_new())!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle {
            adw_action_row_set_subtitle(ptr(row), subtitle)
        }
        adw_switch_row_set_active(ptr(row), gbool(isOn))
        connectNotify(row, "active") {
            changed(adw_switch_row_get_active(ptr(row)) != 0)
        }
        adw_preferences_group_add(ptr(group), ptr(row))
    }

    private static func addCombo(
        to group: GPtr,
        title: String,
        subtitle: String? = nil,
        items: [String],
        selected: Int,
        _ changed: @escaping @MainActor (Int) -> Void
    ) {
        let row = raw(adw_combo_row_new())!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle {
            adw_action_row_set_subtitle(ptr(row), subtitle)
        }
        var cStrings = items.map { strdup($0) }
        cStrings.append(nil)
        let list = cStrings.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                gtk_string_list_new($0)
            }
        }
        cStrings.forEach { free($0) }
        adw_combo_row_set_model(ptr(row), ptr(raw(list)))
        g_object_unref(raw(list))
        adw_combo_row_set_selected(ptr(row), guint(selected))
        connectNotify(row, "selected") {
            let index = Int(adw_combo_row_get_selected(ptr(row)))
            guard items.indices.contains(index) else { return }
            changed(index)
        }
        adw_preferences_group_add(ptr(group), ptr(row))
    }
}
