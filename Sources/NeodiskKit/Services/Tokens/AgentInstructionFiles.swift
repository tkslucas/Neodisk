//
//  AgentInstructionFiles.swift
//  Neodisk
//

import Foundation

/// Files coding agents load into context on their own: instruction and
/// memory files, by name.
public enum AgentInstructionFiles {
    static let names: Set<String> = [
        "claude.md", "claude.local.md", "agents.md", "agent.md", "soul.md", "gemini.md",
        "skill.md", "copilot-instructions.md", ".cursorrules", ".windsurfrules", ".clinerules",
    ]

    public static func matches(_ node: FileNodeRecord) -> Bool {
        guard !node.isDirectory else { return false }
        let name = node.name.lowercased()
        return names.contains(name) || name.hasSuffix(".mdc")
    }
}
