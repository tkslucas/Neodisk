// SwiftUI views never get QLPreviewPanel's responder-chain callbacks, so this singleton claims the shared
// panel's dataSource/delegate on show and releases them on close.

import AppKit
import Quartz
import SwiftUI
import NeodiskKit

@MainActor
final class QuickLookPresenter: NSObject {
    static let shared = QuickLookPresenter()

    /// Real, existing, not cloud-only: previewing a dataless file would force a download, and looking
    /// never changes what is on disk.
    nonisolated static func canPreview(
        _ node: FileNodeRecord,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        node.supportsFileActions && !node.isDataless && fileExists(node.path)
    }

    /// The items vended to the panel, in selection order; its own arrows page through them.
    private var previewedURLs: [NSURL] = []
    private var panelCloseObserver: NSObjectProtocol?

    /// What the panel shows for these items: the previewable ones, and where to start (the current item, or the
    /// first).
    nonisolated static func previewItems(
        for nodes: [FileNodeRecord],
        current: FileNodeRecord?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (urls: [URL], index: Int) {
        let previewable = nodes.filter { canPreview($0, fileExists: fileExists) }
        let index = current.flatMap { current in previewable.firstIndex { $0.id == current.id } } ?? 0
        return (previewable.map(\.url), index)
    }

    func togglePreview(for node: FileNodeRecord) {
        togglePreview(for: [node], current: node)
    }

    /// Closes the panel if it's already up; beeps when nothing can be previewed.
    func togglePreview(for nodes: [FileNodeRecord], current: FileNodeRecord?) {
        if isPanelVisible {
            closePanel()
            return
        }
        guard show(nodes, current: current) else {
            NSSound.beep()
            return
        }
    }

    /// Unlike the space toggle it never closes the panel, and stays quiet when the node can't be previewed.
    func openPreview(for node: FileNodeRecord) {
        _ = show([node], current: node)
    }

    /// No-op when the panel is closed; keeps the last preview rather than blanking on unpreviewable items.
    func selectionDidChange(to nodes: @autoclosure () -> [FileNodeRecord], current: FileNodeRecord?) {
        guard isPanelVisible,
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self else { return }
        let items = Self.previewItems(for: nodes(), current: current)
        guard !items.urls.isEmpty else { return }
        previewedURLs = items.urls.map { $0 as NSURL }
        panel.reloadData()
        panel.currentPreviewItemIndex = items.index
    }

    private func show(_ nodes: [FileNodeRecord], current: FileNodeRecord?) -> Bool {
        let items = Self.previewItems(for: nodes, current: current)
        guard !items.urls.isEmpty else { return false }
        previewedURLs = items.urls.map { $0 as NSURL }
        showPanel(at: items.index)
        return true
    }

    // MARK: - Panel lifecycle

    /// `sharedPreviewPanelExists()` first: `shared()` would instantiate
    /// the panel just to ask whether it is visible.
    private var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    private func showPanel(at index: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        // Re-claim unconditionally: the shared panel is reused and another
        // show may follow a close that never cleared it.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)

        // There is no previewPanelDidClose delegate method, so observe the window notification instead.
        if panelCloseObserver == nil {
            panelCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    QuickLookPresenter.shared.panelWillClose()
                }
            }
        }
    }

    private func closePanel() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        panel.close()
    }

    private func panelWillClose() {
        previewedURLs = []
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
        }
        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
        }
        panelCloseObserver = nil
    }
}

// MARK: - QLPreviewPanelDataSource / Delegate

// @preconcurrency: the ObjC protocols are nonisolated, but QLPreviewPanel
// only ever calls them on the main thread.
extension QuickLookPresenter: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewedURLs.indices.contains(index) ? previewedURLs[index] : nil
    }
}

extension QuickLookPresenter: @preconcurrency QLPreviewPanelDelegate {
    /// Space while the panel itself is key closes it, mirroring Finder.
    /// (Esc is handled natively by the panel.)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers == " " else { return false }
        panel.close()
        return true
    }
}
