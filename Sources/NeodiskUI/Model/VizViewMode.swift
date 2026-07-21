//
//  VizViewMode.swift
//  Neodisk
//
//  Which visualization fills the center pane: the cushion treemap or the
//  sunburst. Raw String so it can persist via AppPreferences.
//

enum VizViewMode: String, CaseIterable, Sendable {
    case treemap
    case sunburst
}

/// Where the file outline docks: the classic compact column left of the
/// visualization, or a wide multi-column table below it. Raw String so it
/// can persist via AppPreferences.
enum OutlinePosition: String, CaseIterable, Sendable {
    case leading
    case bottom
}

/// Which column the bottom outline table orders siblings by. Raw String so
/// it can persist via AppPreferences.
enum OutlineSortField: String, CaseIterable, Sendable {
    case name
    case size
    case files
    case modified
}

/// A bottom-table header sort: column plus direction.
struct OutlineSort: Equatable, Sendable {
    var field: OutlineSortField
    var ascending: Bool
}

/// The view a new session opens with: one of the three center views, or
/// whatever was on screen when the app last closed (the default — the
/// `vizViewMode` + `treemapStyle` pair already persists continuously).
/// Raw String so it can persist via AppPreferences.
enum DefaultVizView: String, CaseIterable, Sendable {
    case lastViewed
    case cushionTreemap
    case flatTreemap
    case sunburst
}
