// Which visualization fills the center pane: the cushion treemap or the
// sunburst. Raw String so it can persist via AppPreferences.

package enum VizViewMode: String, CaseIterable, Sendable {
    case treemap
    case sunburst
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
}
