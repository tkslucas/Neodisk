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
