// Dev env hooks, named like the macOS app's: NEODISK_AUTOSCAN, NEODISK_UI_SNAPSHOT (works under Xvfb),
// NEODISK_SNAPSHOT_DELAY, NEODISK_VIZ_MODE, NEODISK_TREEMAP_STYLE, NEODISK_ANALYSIS_TAB, NEODISK_SELECT,
// NEODISK_AUTOTRASH, NEODISK_POPUP.

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
        model.preferences.overrideForSession(
            vizMode: environment["NEODISK_VIZ_MODE"].flatMap(VizViewMode.init(rawValue:)),
            treemapStyle: environment["NEODISK_TREEMAP_STYLE"].flatMap(TreemapStyle.init(rawValue:))
        )
        if let tab = environment["NEODISK_ANALYSIS_TAB"].flatMap(AnalysisTab.init(rawValue:)) {
            model.analysisTab = tab
        }
        guard let path = environment["NEODISK_AUTOSCAN"] else { return }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        model.open(ScanTarget(url: url))

        // NEODISK_SELECT=<path>[:<path>...]: those items selected once on screen, the last one primary.
        if let rawSelection = environment["NEODISK_SELECT"] {
            let paths = rawSelection.split(separator: ":").map(String.init)
            tokens.append(track {
                guard model.phase == .displaying, model.selection.isEmpty, let store = model.store else { return }
                let ids = paths.filter { store.node(id: $0) != nil }
                guard !ids.isEmpty else { return }
                model.select(ids.last)
                model.selection.replace(with: ids, primary: ids.last)
            })
        }

        // NEODISK_POPUP=primary|sections|status|views|preferences: that menu opens once the scan is on screen.
        if let menu = environment["NEODISK_POPUP"] {
            var opened = false
            tokens.append(track {
                guard !opened, model.phase == .displaying else { return }
                opened = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    window.popUpForCapture(menu)
                }
            })
        }

        let snapshotOutput = environment["NEODISK_UI_SNAPSHOT"]
        let delay = environment["NEODISK_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
        func captureAndQuit(to output: String) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                if capture(window.window, to: output) {
                    FileHandle.standardError.write(Data("neodisk: wrote \(output)\n".utf8))
                } else {
                    FileHandle.standardError.write(Data("neodisk: capture failed\n".utf8))
                }
                g_application_quit(ptr(application))
            }
        }

        // NEODISK_AUTOTRASH=<path>[:<path>...] moves those items as if confirmed, once the scan is on screen: one
        // item alone, several together as a multi-selection goes. Every safety check still runs, and the window
        // reports as it would (with NEODISK_UI_SNAPSHOT, the capture shows the report). One line per item on stderr.
        if let rawPaths = environment["NEODISK_AUTOTRASH"] {
            var started = false
            tokens.append(track {
                guard !started, model.phase == .displaying, model.snapshot?.isComplete == true else { return }
                started = true
                Task { @MainActor in
                    var nodes: [FileNodeRecord] = []
                    for path in rawPaths.split(separator: ":").map(String.init) {
                        if let node = model.store?.node(id: path) {
                            nodes.append(node)
                        } else {
                            FileHandle.standardError.write(Data("NEODISK_AUTOTRASH: \(path): not in the scan\n".utf8))
                        }
                    }
                    var outcomes: [TrashOutcome?] = nodes.map { _ in nil }
                    if nodes.count == 1 {
                        outcomes = [await window.move(nodes[0])]
                    } else if let moved = await window.move(nodes) {
                        outcomes = moved
                    }
                    for (node, outcome) in zip(nodes, outcomes) {
                        let line = switch outcome {
                        case .moved(let bytes): "moved \(bytes) bytes"
                        case .alreadyGone: "already gone"
                        case .failed(let reason): "refused: \(reason)"
                        case nil: "busy"
                        }
                        FileHandle.standardError.write(Data("NEODISK_AUTOTRASH: \(node.path): \(line)\n".utf8))
                    }
                    FileHandle.standardError.write(Data(
                        "NEODISK_AUTOTRASH: done; root \(model.snapshot?.root.allocatedSize ?? -1) bytes\n".utf8
                    ))
                    if let snapshotOutput { captureAndQuit(to: snapshotOutput) }
                }
            })
            return
        }

        guard let snapshotOutput else { return }
        var captured = false
        tokens.append(track {
            guard !captured, model.phase == .displaying, !model.catalog.stats.isEmpty || model.store?.nodeCount ?? 0 < 3 else { return }
            captured = true
            captureAndQuit(to: snapshotOutput)
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
