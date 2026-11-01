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
        case .unreadableFolder:
            AppStrings.localized("Neodisk couldn't look inside this folder, so it can't tell what it holds.", comment: "Trash refusal")
        case .undecodableName:
            AppStrings.localized("This name couldn't be read correctly, so Neodisk can't move it safely.", comment: "Trash refusal")
        case .insideAppBundle:
            AppStrings.localized("This is part of an app or plug-in, which needs it to work. Move the whole app or plug-in instead.", comment: "Trash refusal")
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

    /// `scannedAt`: when the tree was scanned; an old one gets a note, since folders may have changed since.
    package init(
        nodes: [FileNodeRecord],
        scannedAt: Date? = nil,
        now: Date = Date(),
        homeDirectory: String = NSHomeDirectory()
    ) {
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
        let cloudRoots = ["Library/Mobile Documents", "Library/CloudStorage"].flatMap { relative in
            let path = (homeDirectory as NSString).appendingPathComponent(relative)
            return [path, "/System/Volumes/Data" + path]
        }
        // Under a cloud root, holding one, or holding files whose content lives only in a cloud.
        let touchesCloud = nodes.contains { node in
            node.isDataless || node.cloudOnlyLogicalSize > 0 || cloudRoots.contains { root in
                node.path == root || node.path.hasPrefix(root + "/") || root.hasPrefix(node.path + "/")
            }
        }
        if touchesCloud {
            notes.append(AppStrings.localized("Some of this is in a cloud drive: moving it to the Trash also removes it from the cloud and your other devices.", comment: "Trash confirmation note"))
        }
        if nodes.contains(where: { $0.linkCount > 1 || $0.cloneInfo != nil || $0.summarizedClones != nil }) {
            notes.append(AppStrings.localized("Some of this shares storage with other files (hard links or clones), so less space may come back.", comment: "Trash confirmation note"))
        }
        if nodes.contains(where: { $0.isDirectory && !$0.isAccessible }) {
            notes.append(AppStrings.localized("Neodisk couldn't read everything inside some of this, so it may hold more than shown.", comment: "Trash confirmation note"))
        }
        if let scannedAt, now.timeIntervalSince(scannedAt) > 3600 {
            notes.append(String(
                format: AppStrings.localized("This scan is from %@: folders may have changed since. Rescan to be sure.", comment: "Trash confirmation note"),
                scannedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
            ))
        }
        notes.append(AppStrings.localized("The space comes back when you empty the Trash.", comment: "Trash confirmation note"))
        self.notes = notes
    }
}
