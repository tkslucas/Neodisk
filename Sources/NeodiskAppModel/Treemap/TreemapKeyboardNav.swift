//
//  TreemapKeyboardNav.swift
//  Neodisk
//
//  Pure arrow-key resolution for the treemap: which tile the selection
//  moves to from the current selection's center. The candidate tiles are
//  derived once per scene (scenes are immutable), so a key press is one
//  pass over precomputed centers instead of refiltering every cell.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import TreemapKit

package enum TreemapKeyboardNav {
    package enum Direction: Sendable { case up, down, left, right }

    /// A tile the keyboard can land on: its node and precomputed center and
    /// area (the no-selection anchor picks the largest).
    package struct Candidate: Equatable, Sendable {
        package let nodeID: String
        package let center: CGPoint
        package let area: CGFloat
    }

    /// Free-space, hidden-space, and "smaller items" aggregate tiles aren't
    /// real files; navigate only among concrete file/folder tiles. Flat-style
    /// containers are excluded too — their centers sit on top of their
    /// children, which would make spatial movement erratic. Scene order is
    /// kept, so every tie resolves exactly as it did over the cells.
    package nonisolated static func candidates(in cells: [TreemapCell]) -> [Candidate] {
        var candidates: [Candidate] = []
        for cell in cells
        where !cell.isFreeSpace && !cell.isHiddenSpace && cell.aggregate == nil && !cell.isContainer {
            candidates.append(Candidate(
                nodeID: cell.nodeID,
                center: CGPoint(x: cell.rect.midX, y: cell.rect.midY),
                area: cell.rect.width * cell.rect.height
            ))
        }
        return candidates
    }

    /// The anchor with no current selection: the largest tile (first one on
    /// ties), or nil for an empty map.
    package nonisolated static func largest(in candidates: [Candidate]) -> String? {
        candidates.max { $0.area < $1.area }?.nodeID
    }

    /// Nearest tile whose center lies in `direction` from `origin`, biased
    /// toward small perpendicular offset so movement tracks the visual
    /// row/column. The view is flipped, so up = smaller y, down = larger y.
    /// Nil when nothing lies that way (caller beeps).
    package nonisolated static func target(
        from origin: CGPoint,
        direction: Direction,
        excluding selectedNodeID: String?,
        in candidates: [Candidate]
    ) -> String? {
        var best: (nodeID: String, score: CGFloat)?
        for candidate in candidates where candidate.nodeID != selectedNodeID {
            let to = candidate.center
            let dx = to.x - origin.x, dy = to.y - origin.y
            let primary: CGFloat
            let perpendicular: CGFloat
            switch direction {
            case .left: guard dx < -0.5 else { continue }; primary = -dx; perpendicular = abs(dy)
            case .right: guard dx > 0.5 else { continue }; primary = dx; perpendicular = abs(dy)
            case .up: guard dy < -0.5 else { continue }; primary = -dy; perpendicular = abs(dx)
            case .down: guard dy > 0.5 else { continue }; primary = dy; perpendicular = abs(dx)
            }
            let score = primary + 2 * perpendicular
            if best == nil || score < best!.score { best = (candidate.nodeID, score) }
        }
        return best?.nodeID
    }
}
