//
//  QuickLookPresenter.swift
//  Neodisk
//
//  Spacebar Quick Look for the selected node. QLPreviewPanel normally
//  flows through the AppKit responder chain (acceptsPreviewPanelControl /
//  beginPreviewPanelControl); SwiftUI views never get that callback, so
//  this presenter uses the pragmatic pattern instead: claim the shared
//  panel's dataSource/delegate when showing and release them when the
//  panel closes. The presenter is a process-lifetime singleton, so a
//  stale reference on a reused panel can never dangle — and every show()
//  re-claims the panel anyway.
//

import AppKit
import Quartz
import SwiftUI
import NeodiskKit

@MainActor
final class QuickLookPresenter: NSObject {
    static let shared = QuickLookPresenter()

    /// A node previews only if it is a real filesystem item (not the
    /// synthetic "System Data" node) that still exists on disk and is not
    /// cloud-only: previewing a dataless file would force a download, which
    /// the read-only promise forbids. The existence check is injectable for
    /// tests.
    nonisolated static func canPreview(
        _ node: FileNodeRecord,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        node.supportsFileActions && !node.isDataless && fileExists(node.path)
    }

    /// The single item vended to the panel.
    private var previewedURL: NSURL?
    private var panelCloseObserver: NSObjectProtocol?

    /// Space pressed with `node` selected: open the panel previewing it,
    /// or close the panel if it is already up (Finder semantics). Beeps
    /// instead of opening when the node cannot be previewed.
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

    /// A file was clicked in the sunburst (chart segment or legend row):
    /// open the panel previewing it, retargeting an already-open panel.
    /// Unlike the space toggle it never closes the panel, and it stays
    /// quiet when the node cannot be previewed — a click's primary job
    /// (selecting) already succeeded.
    func openPreview(for node: FileNodeRecord) {
        guard Self.canPreview(node) else { return }
        previewedURL = node.url as NSURL
        showPanel()
    }

    /// Selection moved while the panel is up — arrow-keying through the
    /// outline live-updates the preview. No-op when the panel is closed;
    /// keeps the last preview when the new selection is not previewable
    /// (or is nil), rather than blanking the panel.
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

        // There is no previewPanelDidClose delegate method; observe the
        // window notification to release the panel when it goes away
        // (Esc, the close button, or our own space-toggle).
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

/// Space-to-Quick-Look for any list whose selection is the model's
/// selected node. Attach to the List itself: key presses only reach it
/// while the list has focus, so typing spaces into a search TextField is
/// unaffected (the field editor consumes them first) — the explicit
/// text-editing guard below is belt and braces.
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
