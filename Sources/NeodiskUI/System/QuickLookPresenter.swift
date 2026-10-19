// SwiftUI views never get QLPreviewPanel's responder-chain callbacks, so this singleton claims the shared
// panel's dataSource/delegate on show and releases them on close.

import AppKit
import Quartz
import SwiftUI
import NeodiskKit

@MainActor
final class QuickLookPresenter: NSObject {
    static let shared = QuickLookPresenter()

    /// Real, existing, not cloud-only: previewing a dataless file would force a download, which the
    /// read-only promise forbids.
    nonisolated static func canPreview(
        _ node: FileNodeRecord,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        node.supportsFileActions && !node.isDataless && fileExists(node.path)
    }

    /// The single item vended to the panel.
    private var previewedURL: NSURL?
    private var panelCloseObserver: NSObjectProtocol?

    /// Closes the panel if it's already up; beeps when the node can't be previewed.
    func togglePreview(for node: FileNodeRecord) {
        if isPanelVisible {
            closePanel()
            return
        }
        guard Self.canPreview(node) else {
            NSSound.beep()
            return
        }
        previewedURL = node.url as NSURL
        showPanel()
    }

    /// Unlike the space toggle it never closes the panel, and stays quiet when the node can't be previewed.
    func openPreview(for node: FileNodeRecord) {
        guard Self.canPreview(node) else { return }
        previewedURL = node.url as NSURL
        showPanel()
    }

    /// No-op when the panel is closed; keeps the last preview rather than blanking on an unpreviewable node.
    func selectionDidChange(to node: FileNodeRecord?) {
        guard isPanelVisible,
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self,
              let node, Self.canPreview(node) else { return }
        previewedURL = node.url as NSURL
        panel.reloadData()
    }

    // MARK: - Panel lifecycle

    /// `sharedPreviewPanelExists()` first: `shared()` would instantiate
    /// the panel just to ask whether it is visible.
    private var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    private func showPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        // Re-claim unconditionally: the shared panel is reused and another
        // show may follow a close that never cleared it.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
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
        previewedURL = nil
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
        previewedURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewedURL
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

// MARK: - Spacebar hook for selection lists

/// Attach to the List itself: keys only reach it while focused, so typing spaces into a search field
/// is unaffected.
private struct QuickLookSpaceKey: ViewModifier {
    let model: NeodiskViewModel

    func body(content: Content) -> some View {
        content.onKeyPress(.space) {
            guard let node = model.selectedNode else { return .ignored }
            if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
            QuickLookPresenter.shared.togglePreview(for: node)
            return .handled
        }
    }
}

extension View {
    /// Quick Look the model's selected node on space. Attach to selection
    /// Lists (the search results; the AppKit tables handle space themselves).
    func quickLookOnSpace(model: NeodiskViewModel) -> some View {
        modifier(QuickLookSpaceKey(model: model))
    }
}
