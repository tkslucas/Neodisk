// What both apps say about moving items to the Trash: why an item can't go, why a move failed, and the
// confirmation before a move.

import Foundation
import NeodiskKit

package extension TrashRefusal {
    var localizedReason: String {
        switch self {
        case .notAFile:
            AppStrings.localized("This isn't a file or folder, so it can't go to the Trash.", comment: "Trash refusal")
        case .scanRoot:
            AppStrings.localized("This is the location being shown. Scan the folder that holds it to remove it.", comment: "Trash refusal")
        case .protectedLocation:
            AppStrings.localized("This location is protected: the system or your account needs it. What's inside it can go.", comment: "Trash refusal")
        case .alreadyInTrash:
            AppStrings.localized("This is already in the Trash.", comment: "Trash refusal")
        }
    }
}

package extension TrashFailure {
    var localizedReason: String {
        switch self {
        case .refused(let refusal):
            refusal.localizedReason
        case .missing:
            AppStrings.localized("It's no longer there.", comment: "Trash failure")
        case .changedSinceScan:
            AppStrings.localized("It changed since the scan. Rescan to move it.", comment: "Trash failure")
        case .systemError(let message):
            message
        }
    }
}

/// The question asked before a move. Paths, not names, so it's clear exactly what goes.
package struct TrashConfirmation: Sendable, Equatable {
    package let title: String
    package let paths: String
    package let notes: [String]

    package var message: String {
        ([paths] + notes).joined(separator: "\n\n")
    }

    package init(nodes: [FileNodeRecord], homeDirectory: String = NSHomeDirectory()) {
        let total = nodes.reduce(Int64(0)) { $0 &+ $1.allocatedSize }
        title = nodes.count == 1
            ? String(format: AppStrings.localized("Move “%@” to the Trash?", comment: "Trash confirmation title"), nodes[0].name)
            : String(format: AppStrings.localized("Move %lld items (%@) to the Trash?", comment: "Trash confirmation title"), nodes.count, NeodiskFormatters.size(total))

        let shown = nodes.prefix(3).map(\.path)
        var lines = shown
        if nodes.count > shown.count {
            lines.append(String(format: AppStrings.localized("and %lld more", comment: "Trash confirmation, items not listed"), nodes.count - shown.count))
        }
        if nodes.count == 1 {
            lines.append(NeodiskFormatters.size(total))
        }
        paths = lines.joined(separator: "\n")

        var notes: [String] = []
        let cloudRoots = ["Library/Mobile Documents", "Library/CloudStorage"].map {
            (homeDirectory as NSString).appendingPathComponent($0)
        }
        let touchesCloud = nodes.contains { node in
            cloudRoots.contains { root in
                node.path == root || node.path.hasPrefix(root + "/") || root.hasPrefix(node.path + "/")
            }
        }
        if touchesCloud {
            notes.append(AppStrings.localized("Some of this is in a cloud drive: moving it to the Trash also removes it from the cloud and your other devices.", comment: "Trash confirmation note"))
        }
        if nodes.contains(where: { $0.linkCount > 1 || $0.cloneInfo != nil || $0.summarizedClones != nil }) {
            notes.append(AppStrings.localized("Some of this shares storage with other files (hard links or clones), so less space may come back.", comment: "Trash confirmation note"))
        }
        notes.append(AppStrings.localized("The space comes back when you empty the Trash.", comment: "Trash confirmation note"))
        self.notes = notes
    }
}
