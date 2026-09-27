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
    /// Deep-rescan (recursive re-walk) subtree count above which a full scan
    /// wins: hundreds of recursive sub-scans plus a batch splice cost more than
    /// one traversal, and the progress story degrades. Shallow relists are far
    /// cheaper (one readdir each), so they get a much larger budget below.
    static let defaultMaxSubtrees = 128

    /// Shallow-relist directory count above which a full scan wins. Each relist
    /// is a single directory read, so this is generous — scattered churn across
    /// thousands of directories is still a fraction of a full `/` traversal
    /// (hundreds of thousands of directories) — but bounded so a pathological
    /// journal can't turn into a directory-read storm rivaling the full scan.
    static let defaultMaxRelistDirectories = 4096

    static func plan(
        events: [FileSystemChangeEvent],
        target: ScanTarget,
        baseline: FileTreeStore,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        maxSubtrees: Int = defaultMaxSubtrees,
        maxRelistDirectories: Int = defaultMaxRelistDirectories
    ) -> IncrementalRescanPlan {
        let targetPath = target.id
        /// Materialized directories to shallow-relist (one readdir + diff each),
        /// preserving first-seen order. NOT coalesced: a directory and its
        /// changed subdirectory are both relisted independently, which is the
        /// whole point — scattered churn no longer collapses into a re-walk of a
        /// high-mass common ancestor.
        var shallowRootIDs: [String] = []
        var shallowRootIDSet = Set<String>()
        /// Subtrees FSEvents semantics force a recursive re-walk for: a
        /// hierarchical coalesce (MustScanSubDirs) or an auto-summarized /
        /// package directory whose interior the baseline never materialized.
        var deepRootIDs: [String] = []
        var deepRootIDSet = Set<String>()
        /// The scan root's own membership or record moved; it is shallow-relisted
        /// like any other directory. Deferred to the end so it is added exactly
        /// once regardless of how many root-level events name it.
        var rootMembershipChanged = false
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
                // A hierarchical coalesce on the root itself means the whole
                // tree lost granularity — only a full scan is trustworthy. Any
                // other root event (record/membership move) is a shallow relist.
                if event.flags.contains(.mustScanSubdirectories) {
                    return .fullScan(.changedScanRoot)
                }
                rootMembershipChanged = true
                continue
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
            // A new `ln`, say, names only the new link: relisting its folder
            // adds a record whose sibling link elsewhere still reads link
            // count 1 with no identity, so dedup can't pair them and the
            // bytes count twice. Only a full scan re-derives ownership.
            if event.flags.touchesHardLink {
                return .fullScan(.hardLinkTopologyChanged)
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
                // A membership change directly under the scan root (or a
                // direct-child file's own change) lands here. A hierarchical
                // coalesce still demands a full scan; otherwise relist the root
                // shallowly instead of discarding the baseline.
                if event.flags.contains(.mustScanSubdirectories) {
                    return .fullScan(.changedScanRoot)
                }
                rootMembershipChanged = true
                continue
            }

            // A shallow relist can only reconstruct a directory whose children
            // the baseline actually holds. A hierarchical coalesce, or a
            // summarized/package directory (materialized as a childless leaf),
            // must be recursively re-walked so its interior is rebuilt exactly
            // as a full scan would — the coarse, preserved subtree path.
            let matchedNode = baseline.node(id: matched)
            let needsDeepRewalk = event.flags.contains(.mustScanSubdirectories)
                || matchedNode?.isAutoSummarized == true
                || matchedNode?.isPackage == true
            if needsDeepRewalk {
                if deepRootIDSet.insert(matched).inserted { deepRootIDs.append(matched) }
            } else if shallowRootIDSet.insert(matched).inserted {
                shallowRootIDs.append(matched)
            }

            // Cheap early exit: reconciliation below can only shrink the sets,
            // but a runaway window shouldn't accumulate unbounded roots first.
            if shallowRootIDs.count > maxRelistDirectories * 2
                || deepRootIDs.count > maxSubtrees * 4 {
                return .fullScan(.tooManyChangedSubtrees)
            }
        }

        if rootMembershipChanged, shallowRootIDSet.insert(baseline.rootID).inserted {
            shallowRootIDs.append(baseline.rootID)
        }

        // Deep roots are recursively re-walked, so they must be pairwise
        // disjoint; a shallow relist at or under a deep root is redundant (the
        // re-walk rebuilds it) and is dropped.
        let deepCollapsed = baseline.topLevelNodeIDs(from: deepRootIDs)
        let deepSet = Set(deepCollapsed)
        let relistDirIDs = deepSet.isEmpty
            ? shallowRootIDs
            : shallowRootIDs.filter { !baseline.isNodeOrDescendant($0, of: deepSet) }

        guard !relistDirIDs.isEmpty || !deepCollapsed.isEmpty else {
            return .noChanges
        }
        guard relistDirIDs.count <= maxRelistDirectories,
              deepCollapsed.count <= maxSubtrees else {
            return .fullScan(.tooManyChangedSubtrees)
        }
        return .relistDirectories(dirIDs: relistDirIDs, deepRescanRootIDs: deepCollapsed)
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
