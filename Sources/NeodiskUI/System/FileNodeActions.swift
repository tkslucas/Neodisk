// contextMenu(forSelectionType:primaryAction:) is the only way to add double-click to a macOS List
// without breaking selection: every SwiftUI tap gesture swallows the mouse-down NSTableView needs.

import AppKit
import SwiftUI
import NeodiskKit

extension View {
    /// Double-click reveals in Finder, like a treemap cell. No-ops for nodes without file actions
    /// (the synthetic "System Data" node).
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
    /// Keep in lockstep with the SwiftUI `fileNodeActions` above. Nil for nodes without file actions.
    @MainActor
    static func fileNodeActions(for node: FileNodeRecord, model: NeodiskViewModel) -> NSMenu? {
        guard model.supportsFileActions(node) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addFileNodeActionItems(for: node, model: model)
        return menu
    }

    /// The flat statistics lists leave out the contents-expansion item, as their SwiftUI predecessors did.
    @MainActor
    func addFileNodeActionItems(
        for node: FileNodeRecord, model: NeodiskViewModel, includeExpandContents: Bool = true
    ) {
        addItem(ClosureMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "File node context menu")) { model.reveal(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Open", comment: "File node context menu")) { model.open(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Copy Path", comment: "File node context menu")) { model.copyPath(node) })
        if includeExpandContents, let expansion = model.contentsExpansion(for: node) {
            addItem(.separator())
            let item = ClosureMenuItem(title: NSLocalizedString(expansion.menuTitleKey, comment: "File node context menu")) { model.expandNodeContents(node) }
            item.isEnabled = model.canRefreshSubtree
            addItem(item)
        }
    }
}
