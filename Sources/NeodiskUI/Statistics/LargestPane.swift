// The flat-list answer to what the treemap shows spatially; rows select the node in outline and treemap.

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
            rows: model.largest.rows,
            totalMatches: model.largest.totalMatches,
            filterText: $largest.filterText
        )
        // Reload on appear, a new snapshot, or the cloud-only toggle (it changes the ranking).
        .task(id: "\(model.coordinator.snapshot?.id.uuidString ?? "")|\(model.showsCloudOnlyFiles)") {
            model.largest.loadIfNeeded(includeCloudOnly: model.showsCloudOnlyFiles)
        }
    }
}
