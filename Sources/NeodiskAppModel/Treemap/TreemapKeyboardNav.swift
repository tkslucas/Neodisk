// Candidates are derived once per immutable scene, so a key press is one pass over precomputed centers.

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

    /// Flat containers are excluded because their centers sit on their children. Scene order is kept
    /// so ties resolve as they did over the cells.
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

    /// Biased toward small perpendicular offset to track the visual row or column. Flipped view: up is
    /// smaller y.
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
