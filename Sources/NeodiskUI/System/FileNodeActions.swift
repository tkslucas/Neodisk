//
//  FileNodeActions.swift
//  Neodisk
//
//  Context menu + double-click-to-reveal for the selection Lists of file
//  nodes (outline tree, search results, stats drill-ins, duplicate copies).
//
//  Uses contextMenu(forSelectionType:primaryAction:) — the only mechanism
//  that adds double-click to a macOS List without breaking single-click row
//  selection. Every SwiftUI gesture variant (onTapGesture(count: 2),
//  simultaneousGesture, highPriorityGesture) swallows the mouse-down that
//  NSTableView needs for selection; primaryAction hooks the table's native
//  double-click instead.
//

import AppKit
import SwiftUI
import NeodiskKit

extension View {
    /// File actions for a List whose selection type is the node ID:
    /// right-click context menu (Reveal in Finder / Open / Copy Path) and
    /// double-click reveals in Finder — same semantics as double-clicking a
    /// treemap cell. No-ops for nodes without file actions (e.g. the
    /// synthetic "System Data" node).
    ///
    /// `includeExpandContents` adds the outline tree's "Expand Contents" /
    /// "Show Package Contents" item for auto-summarized folders and opaque
    /// packages.
    func fileNodeActions(
        model: NeodiskViewModel, includeExpandContents: Bool = false
    ) -> some View {
        contextMenu(forSelectionType: String.self) { ids in
            if let node = ids.first.flatMap({ model.store?.node(id: $0) }),
               model.supportsFileActions(node) {
                Button("Reveal in Finder") { model.reveal(node) }
                Button("Open") { model.open(node) }
                Button("Copy Path") { model.copyPath(node) }
                if includeExpandContents, let expansion = model.contentsExpansion(for: node) {
                    Divider()
                    Button(LocalizedStringKey(expansion.menuTitleKey)) { model.expandNodeContents(node) }
                        .disabled(!model.canRefreshSubtree)
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first,
                  let node = model.store?.node(id: id),
                  model.supportsFileActions(node) else { return }
            model.select(id)
            model.reveal(node)
        }
    }
}

// MARK: - AppKit variant

/// NSMenuItem that runs a closure; NSMenu's target/action plumbing needs an
/// object to point at, and the item itself is the natural owner.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}

extension NSMenu {
    /// The AppKit file-node context menu shared by the outline table, the
    /// treemap, and the sunburst — the same item list as `fileNodeActions`
    /// above (keep the two in lockstep): Reveal in Finder / Open / Copy
    /// Path, plus the contents-expansion item for summarized folders and
    /// opaque packages. Returns nil for nodes without file actions.
    @MainActor
    static func fileNodeActions(for node: FileNodeRecord, model: NeodiskViewModel) -> NSMenu? {
        guard model.supportsFileActions(node) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addFileNodeActionItems(for: node, model: model)
        return menu
    }

    /// Delegate-driven menus (the outline's menuNeedsUpdate) populate an
    /// existing menu with the same items instead of building a fresh one.
    @MainActor
    func addFileNodeActionItems(for node: FileNodeRecord, model: NeodiskViewModel) {
        addItem(ClosureMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "File node context menu")) { model.reveal(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Open", comment: "File node context menu")) { model.open(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Copy Path", comment: "File node context menu")) { model.copyPath(node) })
        if let expansion = model.contentsExpansion(for: node) {
            addItem(.separator())
            let item = ClosureMenuItem(title: NSLocalizedString(expansion.menuTitleKey, comment: "File node context menu")) { model.expandNodeContents(node) }
            item.isEnabled = model.canRefreshSubtree
            addItem(item)
        }
    }
}
