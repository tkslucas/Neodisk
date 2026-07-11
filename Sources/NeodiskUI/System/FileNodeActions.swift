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
               node.supportsFileActions {
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
                  node.supportsFileActions else { return }
            model.select(id)
            model.reveal(node)
        }
    }
}
