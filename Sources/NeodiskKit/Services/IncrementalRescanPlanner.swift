// Turns replayed FSEvents into the minimal baseline subtrees to re-enumerate. Events are hints for where
// to look, never content; anything it can't map confidently escalates to a full scan.

import Foundation

nonisolated enum IncrementalRescanPlanner {
    /// Above this many recursive re-walks a full scan wins. Shallow relists (one readdir each) get a much
    /// larger budget.
    static let defaultMaxSubtrees = 128

    /// Generous because each relist is one directory read, but bounded so a pathological journal can't
    /// rival a full scan.
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
        /// Deliberately not coalesced: scattered churn must not collapse into a re-walk of a high-mass common
        /// ancestor.
        var shallowRootIDs: [String] = []
        var shallowRootIDSet = Set<String>()
        /// Recursive re-walks: a hierarchical coalesce (MustScanSubDirs) or a summarized/package directory
        /// whose interior the baseline never materialized.
        var deepRootIDs: [String] = []
        var deepRootIDSet = Set<String>()
        /// Deferred to the end so the root is relisted once however many events name it.
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
                // A hierarchical coalesce on the root loses all granularity, so only a full scan is trustworthy.
                if event.flags.contains(.mustScanSubdirectories) {
                    return .fullScan(.changedScanRoot)
                }
                rootMembershipChanged = true
                continue
            }

            // Paths the baseline never covered can't invalidate it. Ancestors are checked too because the scan
            // prunes at an excluded directory and events name its descendants.
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
            // A new link's sibling elsewhere still reads link count 1 with no identity, so a relist would count
            // the bytes twice. Only a full scan re-derives ownership.
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
                // Changes directly under the root relist it shallowly; a hierarchical coalesce still needs a
                // full scan.
                if event.flags.contains(.mustScanSubdirectories) {
                    return .fullScan(.changedScanRoot)
                }
                rootMembershipChanged = true
                continue
            }

            // A shallow relist needs the baseline's children; coalesced, summarized and package directories
            // (childless leaves) must be re-walked recursively.
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

        // Deep roots must be pairwise disjoint; a shallow relist under one is redundant and dropped.
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

    /// Membership changes re-list the parent; a change to a directory's own content re-lists the directory.
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

    /// Nearest real, materialized directory. Packages and summarized directories are leaves but valid roots;
    /// synthetic nodes never match.
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

    /// Hidden components when skipped, excluded names, or pattern matches on the path or an ancestor:
    /// changes there are invisible to the tree.
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
