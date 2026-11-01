// The locations sidebar's sections (which are shown, which are collapsed) and what its rows and Cleanup header say.
// Pure, so both apps and the tests share it.

import Foundation
import NeodiskKit

package enum SidebarSection: String, CaseIterable, Sendable {
    case volumes, cloudFiles, folders, cleanup

    /// The header, a catalog key.
    package var titleKey: String {
        switch self {
        case .volumes: "Volumes"
        case .cloudFiles: "Local Cloud Files"
        case .folders: "Folders"
        case .cleanup: "Cleanup"
        }
    }
}

/// Stored as two comma-separated id lists. Cleanup's visibility is the "Allow moving items to the Trash" preference,
/// never stored here, so turning it off in either place is the same switch.
package struct SidebarSectionState: Equatable, Sendable {
    package private(set) var hidden: Set<SidebarSection>
    package private(set) var collapsed: Set<SidebarSection>

    package init(hidden: String = "", collapsed: String = "") {
        self.hidden = Self.decode(hidden).subtracting([.cleanup])
        self.collapsed = Self.decode(collapsed)
    }

    package var storedHidden: String { Self.encode(hidden) }
    package var storedCollapsed: String { Self.encode(collapsed) }

    package func isShown(_ section: SidebarSection, cleanupEnabled: Bool) -> Bool {
        section == .cleanup ? cleanupEnabled : !hidden.contains(section)
    }

    package func isExpanded(_ section: SidebarSection) -> Bool { !collapsed.contains(section) }

    /// Cleanup is left to the caller (it's the Trash preference).
    package mutating func setShown(_ section: SidebarSection, _ shown: Bool) {
        guard section != .cleanup else { return }
        if shown { hidden.remove(section) } else { hidden.insert(section) }
    }

    package mutating func setExpanded(_ section: SidebarSection, _ expanded: Bool) {
        if expanded { collapsed.remove(section) } else { collapsed.insert(section) }
    }

    /// Shown and expanded, as the toolbar's Cleanup button asks for.
    package mutating func reveal(_ section: SidebarSection) {
        setShown(section, true)
        setExpanded(section, true)
    }

    private static func decode(_ stored: String) -> Set<SidebarSection> {
        Set(stored.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) })
    }

    private static func encode(_ sections: Set<SidebarSection>) -> String {
        SidebarSection.allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// A sidebar row's two lines and tooltip.
package enum SidebarRowText {
    /// Trailing the name: a volume's free space, a folder's scanned size; nil for a folder never scanned.
    package static func size(space: VolumeSpaceInfo?, scannedBytes: Int64?) -> String? {
        if let space, space.totalCapacity > 0 {
            let free = NeodiskFormatters.size(space.availableCapacity)
            return String(format: AppStrings.localized("%@ free", comment: "Sidebar volume row"), free)
        }
        return scannedBytes.map(NeodiskFormatters.size)
    }

    package static func scanned(_ date: Date?, now: Date = Date()) -> String? {
        date.map {
            let relative = DisplayFormatters.relativeDate($0, relativeTo: now)
            return String(format: AppStrings.localized("Scanned %@", comment: "Sidebar row"), relative)
        }
    }

    /// The full path, and under it a volume's capacity.
    package static func tooltip(path: String, space: VolumeSpaceInfo?) -> String {
        guard let space, space.totalCapacity > 0 else { return path }
        return path + "\n" + String(
            format: AppStrings.localized("%@ free of %@", comment: "Sidebar volume tooltip"),
            NeodiskFormatters.size(space.availableCapacity), NeodiskFormatters.size(space.totalCapacity)
        )
    }
}

package enum CleanupText {
    /// The Cleanup header's "1.2 GB · 3 items"; nil when nothing is collected.
    package static func summary(count: Int, totalSize: Int64) -> String? {
        guard count > 0 else { return nil }
        return AppStrings.plural(
            count, one: "%@ · %@ item", other: "%@ · %@ items", NeodiskFormatters.size(totalSize), count.formatted()
        )
    }
}
