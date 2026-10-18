// Scan warnings behind the notice strip, plus the Full Disk Access probe that decides whether permission
// warnings are worth surfacing.

import Foundation
import Observation
import NeodiskKit

/// Warnings that failed under a common ancestor, collapsed to one popover
/// row ("~/Library/Mail · 8").
struct ScanWarningGroup: Identifiable {
    /// Ancestor path shared by the grouped warnings; for a lone warning,
    /// the warning's own path.
    let path: String
    let count: Int
    /// Every grouped warning is permission-denied (drives the lock icon).
    let isPermissionDenied: Bool
    /// Up to five member paths with their error messages, for the row tooltip.
    let details: [String]

    var id: String { path }
}

@MainActor
@Observable
final class ScanWarningsModel {
    /// Once granted, remaining permission warnings are unfixable (other homes, SIP paths), so they're hidden.
    var fullDiskAccessStatus: FullDiskAccessStatus = .unknown

    @ObservationIgnored private let coordinator: ScanCoordinator

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
    }

    func refreshFullDiskAccessStatus() async {
        fullDiskAccessStatus = await Task.detached(priority: .utility) {
            SystemIntegration.fullDiskAccessStatus()
        }.value
    }

    /// Scan warnings the notice strip counts: deduplicated, and without the
    /// permission-denied ones once Full Disk Access is granted.
    var visible: [ScanWarning] {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return [] }
        let hidePermissionDenied = fullDiskAccessStatus == .granted
        // Eager loop: a lazy filter whose predicate mutates state (the seen-ID
        // dedupe) violates Collection semantics.
        var seenIDs = Set<ScanWarning.ID>()
        var visible: [ScanWarning] = []
        for warning in snapshot.scanWarnings {
            if hidePermissionDenied && warning.category == .permissionDenied { continue }
            // Warning identity is content-derived, so repeat warnings for the
            // same path collapse to one.
            guard seenIDs.insert(warning.id).inserted else { continue }
            visible.append(warning)
        }
        return visible
    }

    /// The popover's rows: visible warnings collapsed onto shallow shared
    /// ancestors, largest group first.
    var groups: [ScanWarningGroup] {
        var membersByKey: [String: [ScanWarning]] = [:]
        for warning in visible {
            membersByKey[Self.groupAncestor(of: warning.path), default: []].append(warning)
        }
        return membersByKey
            .map { key, members in
                ScanWarningGroup(
                    path: members.count == 1 ? members[0].path : key,
                    count: members.count,
                    isPermissionDenied: members.allSatisfy { $0.category == .permissionDenied },
                    details: members.prefix(5).map { "\($0.path) — \($0.message)" }
                )
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }
    }

    /// Whether the popover offers the Full Disk Access shortcut: only when
    /// granting would actually unlock one of the failed paths.
    var suggestFullDiskAccess: Bool {
        PermissionAdvisor.shouldSuggestFullDiskAccess(
            for: coordinator.snapshot,
            fullDiskAccessStatus: fullDiskAccessStatus
        )
    }

    /// Two components below home ("~/Library/Mail"), three elsewhere ("/private/var/folders").
    static func groupAncestor(of path: String) -> String {
        let home = NSHomeDirectory()
        let base: String
        let keepComponents: Int
        if path.hasPrefix(home + "/") {
            base = home
            keepComponents = 2
        } else {
            base = ""
            keepComponents = 3
        }
        let components = path.dropFirst(base.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(keepComponents)
        guard !components.isEmpty else { return path }
        return base + "/" + components.joined(separator: "/")
    }
}
