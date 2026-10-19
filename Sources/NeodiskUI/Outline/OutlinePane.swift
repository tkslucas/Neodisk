// Names lay out at full width and pan horizontally under a pinned trailing size cluster. One NSScrollView owns
// both axes (nested SwiftUI scroll views can't pan diagonally) over a recycling NSTableView of SwiftUI rows.

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

/// Filtering never navigates or zooms; only the outline's list changes.
struct OutlineSearchField: View {
    let model: NeodiskViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var search = model.search
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .neoFont(10)
                .foregroundStyle(.secondary)
            TextField("Search entire scan", text: $search.text)
                .textFieldStyle(.plain)
                .neoFont(11)
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
                        .neoFont(10)
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
