//
//  LargestPane.swift
//  Neodisk
//
//  The statistics panel's Largest tab: the whole scan's biggest files,
//  largest first — the flat-list answer to "what's eating my disk" the
//  treemap answers spatially. Rows are the shared read-only navigation:
//  clicking selects the node in the outline and treemap.
//

import SwiftUI
import NeodiskKit

struct LargestPane: View {
    let model: NeodiskViewModel

    var body: some View {
        @Bindable var largest = model.largest
        StatsFileListView(
            model: model,
            title: "Largest Files",
            swatch: nil,
            isLoading: model.largest.isLoading,
            visibleIDs: model.largest.visibleIDs,
            totalMatches: model.largest.totalMatches,
            filterText: $largest.filterText
        )
        // Covers both ways the list goes stale while the tab is on screen:
        // switching to the tab (appear) and a new snapshot landing (id).
        .task(id: model.coordinator.snapshot?.id) {
            model.largest.loadIfNeeded()
        }
    }
}
