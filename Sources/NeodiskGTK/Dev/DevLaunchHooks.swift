//
//  DevLaunchHooks.swift
//  NeodiskGTK
//
//  Environment-variable hooks for development and headless verification,
//  named like the macOS app's:
//
//    NEODISK_AUTOSCAN=<path>        open that location on launch
//    NEODISK_UI_SNAPSHOT=<out.png>  once the scan is on screen, render the
//                                   window to a PNG and quit (works under
//                                   Xvfb or a headless compositor — nothing
//                                   needs to reach a real display)
//    NEODISK_SNAPSHOT_DELAY=<secs>  settle time before the capture (1.5)
//    NEODISK_VIZ_MODE=<treemap|sunburst>, NEODISK_TREEMAP_STYLE=<cushion|flat>,
//    NEODISK_ANALYSIS_TAB=<largest|kinds|age>
//                                   show that view without persisting it
//    NEODISK_SELECT=<path>          select that node once displayed
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit

@MainActor
enum DevLaunchHooks {
    private static var tokens: [ObservationToken] = []

    static func run(model: AppModel, window: MainWindow, application: GPtr) {
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["NEODISK_VIZ_MODE"].flatMap(VizViewMode.init(rawValue:)) {
            model.preferences.vizMode = mode
        }
        if let style = environment["NEODISK_TREEMAP_STYLE"].flatMap(TreemapStyle.init(rawValue:)) {
            model.preferences.treemapStyle = style
        }
        if let tab = environment["NEODISK_ANALYSIS_TAB"].flatMap(AnalysisTab.init(rawValue:)) {
            model.analysisTab = tab
        }
        guard let path = environment["NEODISK_AUTOSCAN"] else { return }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        model.open(ScanTarget(url: url))

        if let selection = environment["NEODISK_SELECT"] {
            tokens.append(track {
                guard model.phase == .displaying, model.store?.node(id: selection) != nil,
                      model.selectedNodeID == nil else { return }
                model.select(selection)
            })
        }

        guard let output = environment["NEODISK_UI_SNAPSHOT"] else { return }
        let delay = environment["NEODISK_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
        var captured = false
        tokens.append(track {
            guard !captured, model.phase == .displaying, !model.catalog.stats.isEmpty || model.store?.nodeCount ?? 0 < 3 else { return }
            captured = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                if capture(window.window, to: output) {
                    FileHandle.standardError.write(Data("neodisk: wrote \(output)\n".utf8))
                } else {
                    FileHandle.standardError.write(Data("neodisk: capture failed\n".utf8))
                }
                g_application_quit(ptr(application))
            }
        })
    }

    /// Renders `widget` (the whole window content) through its own GSK
    /// renderer into a texture and saves it as PNG.
    static func capture(_ widget: GPtr, to path: String) -> Bool {
        let width = gtk_widget_get_width(ptr(widget))
        let height = gtk_widget_get_height(ptr(widget))
        guard width > 0, height > 0,
              let paintable = gtk_widget_paintable_new(ptr(widget)),
              let snapshot = gtk_snapshot_new() else { return false }
        defer { g_object_unref(raw(paintable)) }
        gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return false }
        defer { gsk_render_node_unref(node) }
        guard let native = gtk_widget_get_native(ptr(widget)),
              let renderer = gtk_native_get_renderer(native) else { return false }
        var viewport = graphene_rect_t(
            origin: graphene_point_t(x: 0, y: 0),
            size: graphene_size_t(width: Float(width), height: Float(height))
        )
        guard let texture = gsk_renderer_render_texture(renderer, node, &viewport) else { return false }
        defer { g_object_unref(raw(texture)) }
        return gdk_texture_save_to_png(texture, path) != 0
    }
}
