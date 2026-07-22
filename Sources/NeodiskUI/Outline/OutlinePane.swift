//
//  OutlinePane.swift
//  Neodisk
//
//  The left-hand outline: an expandable name/size tree over the scan,
//  flattened to visible rows so expansion can be driven programmatically
//  (treemap clicks auto-reveal their row).
//
//  Deep nesting can outgrow the pane, so the tree scrolls horizontally.
//  Design: names lay out at full natural width (never truncated) and pan
//  under a viewport-pinned trailing cluster — each row's size (and diff
//  delta) stays right-aligned at the pane edge at every scroll offset,
//  behind a short fade so long names slide beneath it. One AppKit
//  NSScrollView owns both axes (nested SwiftUI scroll views cannot pan
//  diagonally and bounce on row clicks), a single-column NSTableView
//  recycles rows, and the rows themselves stay SwiftUI. When everything
//  fits, offset is zero and the pane renders exactly like the previous
//  SwiftUI List, whose metrics are mirrored in OutlineRowMetrics.
//

import SwiftUI

struct OutlinePane: View {
    let model: NeodiskViewModel

    var body: some View {
        VStack(spacing: 0) {
            OutlineSearchField(model: model)
            Divider()
            if let results = model.search.results {
                OutlineSearchResultsList(model: model, results: results)
            } else {
                outlineTree
            }
        }
    }

    /// The AppKit-backed tree. The search field and search results live
    /// outside it and never pan horizontally.
    private var outlineTree: some View {
        let snapshot = model.outlineRowsSnapshot()
        return OutlineTreeTable(
            model: model,
            snapshot: snapshot,
            selectedID: model.selectedNodeID
        )
    }
}

/// Entire-scan fuzzy search, shared by both outline layouts. Filtering
/// never navigates or zooms — the treemap stays exactly where it is; only
/// the outline's list changes.
struct OutlineSearchField: View {
    let model: NeodiskViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var search = model.search
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search entire scan", text: $search.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isSearchFocused)
                .onExitCommand {
                    model.search.clear()
                    isSearchFocused = false
                }
            if !model.search.text.isEmpty {
                Button {
                    model.search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.search.focusToken) { _, _ in
            isSearchFocused = true
        }
    }
}
