// Which visualization fills the center pane: the cushion treemap or the
// sunburst. Raw String so it can persist via AppPreferences.

import TreemapKit

package enum VizViewMode: String, CaseIterable, Sendable {
    case treemap
    case sunburst
}

/// The views the toolbar picker offers; an `ItemLayout<VizView>` holds which ones it shows.
package enum VizView: String, CaseIterable, Sendable {
    case cushion, flat, sunburst

    package init(mode: VizViewMode, style: TreemapStyle) {
        self = mode == .sunburst ? .sunburst : style == .flat ? .flat : .cushion
    }

    package var mode: VizViewMode { self == .sunburst ? .sunburst : .treemap }

    package var menuTitle: String {
        switch self {
        case .cushion: AppStrings.localized("Cushion Treemap", comment: "View menu")
        case .flat: AppStrings.localized("Flat Treemap", comment: "View menu")
        case .sunburst: AppStrings.localized("Sunburst", comment: "View menu")
        }
    }

    /// Nil for Sunburst, which keeps the treemap style for the trip back.
    package var treemapStyle: TreemapStyle? {
        switch self {
        case .cushion: .cushion
        case .flat: .flat
        case .sunburst: nil
        }
    }
}

/// Raw String so it can persist via AppPreferences.
package enum OutlinePosition: String, CaseIterable, Sendable {
    case leading
    case bottom
}

/// Which column the bottom outline table orders siblings by. Raw String so
/// it can persist via AppPreferences.
package enum OutlineSortField: String, CaseIterable, Sendable {
    case name
    case size
    case files
    case modified
}

/// A bottom-table header sort: column plus direction.
package struct OutlineSort: Equatable, Sendable {
    package var field: OutlineSortField
    package var ascending: Bool

    package init(field: OutlineSortField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

/// The default restores the last view, since `vizViewMode` and `treemapStyle` already persist.
/// Raw String so it can persist via AppPreferences.
package enum DefaultVizView: String, CaseIterable, Sendable {
    case lastViewed
    case cushionTreemap
    case flatTreemap
    case sunburst

    package init(_ view: VizView) {
        switch view {
        case .cushion: self = .cushionTreemap
        case .flat: self = .flatTreemap
        case .sunburst: self = .sunburst
        }
    }

    /// Nil for Last viewed.
    package var view: VizView? {
        switch self {
        case .lastViewed: nil
        case .cushionTreemap: .cushion
        case .flatTreemap: .flat
        case .sunburst: .sunburst
        }
    }
}
