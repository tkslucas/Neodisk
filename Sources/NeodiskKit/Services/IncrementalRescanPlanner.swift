//
//  IncrementalRescanPlanner.swift
//  Neodisk
//
//  Turns a replayed FSEvents window into the minimal set of baseline-tree
//  subtrees to re-enumerate. Pure: no filesystem access, no FSEvents types —
//  events are hints for WHERE to look, never trusted for content, and any
//  event the planner cannot map confidently escalates to a full scan.
//

import Foundation

nonisolated enum IncrementalRescanPlanner {
    /// Changed-subtree count above which a full scan wins: hundreds of
    /// sub-scans plus a batch splice cost more than one traversal, and the
    /// progress story degrades.
    static let defaultMaxSubtrees = 128

    static func plan(
        events: [FileSystemChangeEvent],
        target: ScanTarget,
        baseline: FileTreeStore,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        maxSubtrees: Int = defaultMaxSubtrees
    ) -> IncrementalRescanPlan {
        let targetPath = target.id
        var matchedRootIDs: [String] = []
        var matchedRootIDSet = Set<String>()
        /// Candidate paths whose ancestor walk already ran — event bursts
        /// name the same few directories thousands of times.
        var resolvedCandidates = Set<String>()

        for event in events {
            if let reason = fullScanReason(for: event.flags) {
                return .fullScan(reason)
            }

            let path = normalized(event.path)
            guard path == targetPath || isPath(path, containedIn: targetPath) else {
                return .fullScan(.eventOutsideTarget)
            }
            guard path != targetPath else {
                return .fullScan(.changedScanRoot)
            }

            // Content the baseline scan never covered can't invalidate it:
            // hidden components (when the scan skipped hidden files),
            // startup-volume internals, and excluded paths — checked for
            // the path and every ancestor, because the scan prunes at the
            // excluded directory and events name its descendants — all
            // change without consequence for the tree.
            let baselineNode = baseline.node(id: path)
            if isPathSkipped(
                path,
                isDirectoryHint: baselineNode?.isDirectory ?? event.flags.contains(.itemIsDirectory),
                targetPath: targetPath,
                options: options,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            ) {
                continue
            }

            let candidate = rescanCandidate(
                for: path,
                flags: event.flags,
                baselineNode: baselineNode
            )
            guard resolvedCandidates.insert(candidate).inserted else { continue }

            guard let matched = materializedAncestor(
                of: candidate,
                targetPath: targetPath,
                baseline: baseline
            ) else {
                return .fullScan(.noMaterializedAncestor)
            }
            guard matched != baseline.rootID, matched != targetPath else {
                // Rescanning the root IS the full scan; a membership change
                // directly under the scan root lands here.
                return .fullScan(.changedScanRoot)
            }
            if matchedRootIDSet.insert(matched).inserted {
                matchedRootIDs.append(matched)
                // Cheap early exit: collapse can only shrink the set, but a
                // runaway window shouldn't accumulate unbounded roots first.
                if matchedRootIDs.count > maxSubtrees * 4 {
                    return .fullScan(.tooManyChangedSubtrees)
                }
            }
        }

        guard !matchedRootIDs.isEmpty else { return .noChanges }

        let collapsedRootIDs = baseline.topLevelNodeIDs(from: matchedRootIDs)
        guard !collapsedRootIDs.isEmpty else { return .noChanges }
        guard collapsedRootIDs.count <= maxSubtrees else {
            return .fullScan(.tooManyChangedSubtrees)
        }
        return .rescanSubtrees(collapsedRootIDs)
    }

    // MARK: - Event interpretation

    private static func fullScanReason(for flags: FileSystemEventFlags) -> IncrementalFullScanReason? {
        if flags.contains(.userDropped) { return .userDroppedEvents }
        if flags.contains(.kernelDropped) { return .kernelDroppedEvents }
        if flags.contains(.eventIDsWrapped) { return .eventIDsWrapped }
        if flags.contains(.rootChanged) { return .watchedRootChanged }
        if flags.contains(.volumeMounted) || flags.contains(.volumeUnmounted) {
            return .nestedVolumeChanged
        }
        return nil
    }

    /// The deepest path worth re-enumerating for one event. Membership
    /// changes (create/remove/rename) must re-list the parent; a change to a
    /// directory's own content or attributes re-lists the directory itself.
    private static func rescanCandidate(
        for path: String,
        flags: FileSystemEventFlags,
        baselineNode: FileNodeRecord?
    ) -> String {
        if flags.contains(.mustScanSubdirectories) {
            return path
        }
        if !flags.indicatesMembershipChange {
            if flags.contains(.itemIsDirectory) {
                return path
            }
            if baselineNode?.isDirectory == true {
                return path
            }
        }
        return parentPath(of: path)
    }

    /// Walks up from `candidate` to the nearest baseline node that is a
    /// real, materialized directory — the unit the engine can rescan.
    /// Packages and auto-summarized directories are leaves in the tree but
    /// valid rescan roots (the sub-scan re-summarizes them); synthetic
    /// nodes are not real filesystem paths and never match.
    private static func materializedAncestor(
        of candidate: String,
        targetPath: String,
        baseline: FileTreeStore
    ) -> String? {
        var cursor = candidate
        while cursor == targetPath || isPath(cursor, containedIn: targetPath) {
            if let node = baseline.node(id: cursor), node.isDirectory, !node.isSynthetic {
                return cursor
            }
            guard cursor != targetPath, cursor != "/" else { return nil }
            cursor = parentPath(of: cursor)
        }
        return nil
    }

    // MARK: - Coverage filters

    /// Whether the baseline scan never covered this path: hidden components
    /// when hidden files were skipped, names the scan behavior excludes
    /// (`/Volumes`, `/System/Volumes`, …), or exclusion-pattern matches on
    /// the path or any ancestor below the target. Changes there are
    /// invisible to the tree by construction.
    private static func isPathSkipped(
        _ path: String,
        isDirectoryHint: Bool,
        targetPath: String,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher
    ) -> Bool {
        let relative = path == targetPath ? "" : String(path.dropFirst(
            targetPath == "/" ? 1 : targetPath.count + 1
        ))
        guard !relative.isEmpty else { return false }

        var cursor = targetPath
        for component in relative.split(separator: "/") {
            let name = String(component)
            if !options.includeHiddenFiles && name.hasPrefix(".") {
                return true
            }
            if !ScanEngine.includedChildName(
                name,
                under: URL(filePath: cursor, directoryHint: .isDirectory),
                behavior: behavior
            ) {
                return true
            }
            cursor = cursor == "/" ? "/" + name : cursor + "/" + name
            let isDirectory = cursor == path ? isDirectoryHint : true
            if exclusionMatcher.excludes(
                URL(filePath: cursor, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                isDirectory: isDirectory
            ) {
                return true
            }
        }
        return false
    }

    // MARK: - Path helpers

    private static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func isPath(_ path: String, containedIn rootPath: String) -> Bool {
        guard rootPath != "/" else { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(rootPath + "/")
    }

    private static func parentPath(of path: String) -> String {
        guard let lastSeparator = path.lastIndex(of: "/"), path != "/" else { return "/" }
        let parent = String(path[path.startIndex..<lastSeparator])
        return parent.isEmpty ? "/" : parent
    }
}
