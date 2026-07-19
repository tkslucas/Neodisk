//
//  TreemapStyle.swift
//  TreemapKit
//
//  How the treemap draws and behaves: the classic cushion-shaded map
//  or the flat nested-box style, where folders render as bordered
//  containers with a header strip and their children nest inside.
//  Raw String so it can persist
//  via AppPreferences.
//

public enum TreemapStyle: String, CaseIterable, Sendable {
    case cushion
    case flat
}
