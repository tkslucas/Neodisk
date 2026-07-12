//
//  CloudTreeBuilder.swift
//  Neodisk
//
//  Assembles provider listing pages into the FileTreeStore the rest of the
//  app renders. Entries arrive in arbitrary order (a child can precede its
//  folder), so the builder only accumulates in add(_:) and resolves
//  topology at build time — cheap enough for the ~1.5s partial cadence.
//
//  Identity: node IDs derive from provider file IDs (stable across renames);
//  display paths are synthesized from names, with same-name siblings
//  disambiguated by a short file-ID suffix so path-keyed consumers (search,
//  kinds, diff) keep working.
//

import Foundation
import NeodiskKit

public struct CloudTreeBuilder: Sendable {
    /// Synthetic file IDs, namespaced so they can never collide with a
    /// provider's own IDs (Drive IDs are alphanumeric).
    static let sharedOrphanedFileID = "#shared-orphaned"
    static let unattributedFileID = "#unattributed"
    /// Prefix for folders synthesized from path linkage.
    static let pathFolderIDPrefix = "#path:"

    public let target: ScanTarget
    public let providerID: String
    public let rootFolderID: String

    private var entriesByID: [String: CloudFileEntry] = [:]
    /// Insertion order of first appearance, so sibling-name disambiguation
    /// is stable across partial rebuilds.
    private var orderedEntryIDs: [String] = []

    public private(set) var fileCount = 0
    public private(set) var folderCount = 0
    public private(set) var allocatedBytesDiscovered: Int64 = 0
    /// Name of the most recently added entry, for progress display.
    public private(set) var latestEntryName: String?

    public init(target: ScanTarget, providerID: String, rootFolderID: String) {
        self.target = target
        self.providerID = providerID
        self.rootFolderID = rootFolderID
    }

    public mutating func add(_ entries: [CloudFileEntry]) {
        for entry in entries {
            guard entry.id != rootFolderID else { continue }
            if entriesByID.updateValue(entry, forKey: entry.id) == nil {
                orderedEntryIDs.append(entry.id)
                if entry.isFolder {
                    folderCount += 1
                } else {
                    fileCount += 1
                    allocatedBytesDiscovered = clampedAdd(
                        allocatedBytesDiscovered, entry.allocatedBytes
                    )
                }
            }
            latestEntryName = entry.name
        }
    }

    /// Materializes the tree from everything added so far. `quota` feeds the
    /// synthetic "Unattributed" leaf (trash, versions, provider overhead) on
    /// complete builds only — mid-scan the missing remainder is unscanned,
    /// not unattributed.
    public func buildTree(isComplete: Bool, quota: CloudQuota?) -> FileTreeStore {
        let linked = resolvedEntries()
        var childIDsByParent: [String: [String]] = [:]
        for id in linked.orderedIDs {
            guard let parentID = linked.entries[id]?.parentID else { continue }
            childIDsByParent[parentID, default: []].append(id)
        }

        // Reachability from the drive root; whatever remains hangs under the
        // synthetic Shared & Orphaned bucket (shared-with-me items, parents
        // outside the listed scope) so nothing silently disappears. A parent
        // cycle would leave entries unvisited — promote survivors until all
        // entries land somewhere.
        var reachable = descendants(of: rootFolderID, in: childIDsByParent)
        var orphanRootIDs: [String] = []
        if reachable.count < linked.orderedIDs.count {
            var unvisited = linked.orderedIDs.filter { !reachable.contains($0) }
            while let candidate = firstOrphanRoot(among: unvisited, entries: linked.entries, reachable: reachable) {
                orphanRootIDs.append(candidate)
                reachable.formUnion(descendants(of: candidate, in: childIDsByParent))
                reachable.insert(candidate)
                unvisited.removeAll { reachable.contains($0) }
            }
        }

        return materialize(
            entries: linked.entries,
            childIDsByParent: childIDsByParent,
            orphanRootIDs: orphanRootIDs,
            isComplete: isComplete,
            quota: quota
        )
    }

    // MARK: - Linkage resolution

    private struct LinkedEntries {
        var entries: [String: CloudFileEntry]
        var orderedIDs: [String]
    }

    /// Gives every entry an effective parentID. Path-linked entries (no
    /// parentID, pathComponents set) get their intermediate folders
    /// synthesized, reusing a provider folder entry when one exists at the
    /// same path.
    private func resolvedEntries() -> LinkedEntries {
        var entries = entriesByID
        var orderedIDs = orderedEntryIDs

        let pathLinkedIDs = orderedIDs.filter { id in
            let entry = entries[id]!
            return entry.parentID == nil && entry.pathComponents != nil
        }
        guard !pathLinkedIDs.isEmpty else {
            return LinkedEntries(entries: entries, orderedIDs: orderedIDs)
        }

        // Explicit folders indexed by their full path.
        var folderIDByPath: [String: String] = [:]
        for id in pathLinkedIDs {
            let entry = entries[id]!
            guard entry.isFolder, let components = entry.pathComponents else { continue }
            folderIDByPath[pathKey(components)] = id
        }

        for id in pathLinkedIDs {
            guard let components = entries[id]?.pathComponents, !components.isEmpty else {
                entries[id] = reparented(entries[id]!, to: rootFolderID)
                continue
            }
            var parentID = rootFolderID
            for depth in 1..<components.count {
                let prefix = Array(components[0..<depth])
                let key = pathKey(prefix)
                let folderID: String
                if let existing = folderIDByPath[key] {
                    folderID = existing
                } else {
                    folderID = Self.pathFolderIDPrefix + key
                    folderIDByPath[key] = folderID
                    entries[folderID] = CloudFileEntry(
                        id: folderID,
                        name: prefix[prefix.count - 1],
                        parentID: nil,
                        isFolder: true
                    )
                    orderedIDs.append(folderID)
                }
                if entries[folderID]?.parentID == nil {
                    entries[folderID] = reparented(entries[folderID]!, to: parentID)
                }
                parentID = folderID
            }
            if entries[id]?.parentID == nil {
                entries[id] = reparented(entries[id]!, to: parentID)
            }
        }
        return LinkedEntries(entries: entries, orderedIDs: orderedIDs)
    }

    private func reparented(_ entry: CloudFileEntry, to parentID: String) -> CloudFileEntry {
        CloudFileEntry(
            id: entry.id,
            name: entry.name,
            parentID: parentID,
            pathComponents: entry.pathComponents,
            isFolder: entry.isFolder,
            logicalBytes: entry.logicalBytes,
            quotaBytes: entry.quotaBytes,
            modifiedAt: entry.modifiedAt,
            contentHash: entry.contentHash,
            kindHint: entry.kindHint,
            isOwnedByMe: entry.isOwnedByMe
        )
    }

    private func pathKey(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    // MARK: - Reachability

    private func descendants(of rootID: String, in childIDsByParent: [String: [String]]) -> Set<String> {
        var visited: Set<String> = []
        var stack = childIDsByParent[rootID] ?? []
        while let id = stack.popLast() {
            guard visited.insert(id).inserted else { continue }
            if let childIDs = childIDsByParent[id] {
                stack.append(contentsOf: childIDs)
            }
        }
        return visited
    }

    /// Prefers true orphans (missing/absent parent); falls back to any
    /// unvisited entry to break parent cycles.
    private func firstOrphanRoot(
        among unvisited: [String],
        entries: [String: CloudFileEntry],
        reachable: Set<String>
    ) -> String? {
        guard !unvisited.isEmpty else { return nil }
        for id in unvisited {
            guard let parentID = entries[id]?.parentID else { return id }
            if entries[parentID] == nil && parentID != rootFolderID { return id }
        }
        return unvisited.first
    }

    // MARK: - Materialization

    private func materialize(
        entries: [String: CloudFileEntry],
        childIDsByParent: [String: [String]],
        orphanRootIDs: [String],
        isComplete: Bool,
        quota: CloudQuota?
    ) -> FileTreeStore {
        var childrenByNodeID: [String: [FileNodeRecord]] = [:]

        var rootChildren = buildSubtrees(
            ofParent: rootFolderID,
            parentPath: target.id,
            entries: entries,
            childIDsByParent: childIDsByParent,
            childrenByNodeID: &childrenByNodeID
        )

        if !orphanRootIDs.isEmpty {
            let bucketID = CloudTargetID.nodeID(targetID: target.id, fileID: Self.sharedOrphanedFileID)
            let bucketPath = target.id + "/" + Self.sharedOrphanedName
            let bucketChildren = buildSubtrees(
                ofParent: nil,
                rootIDs: orphanRootIDs,
                parentPath: bucketPath,
                entries: entries,
                childIDsByParent: childIDsByParent,
                childrenByNodeID: &childrenByNodeID
            )
            let bucket = directoryRecord(
                id: bucketID,
                path: bucketPath,
                name: Self.sharedOrphanedName,
                children: bucketChildren,
                fileIdentity: nil,
                lastModified: nil,
                isSynthetic: true
            )
            childrenByNodeID[bucketID] = bucketChildren
            rootChildren.append(bucket)
        }

        if isComplete, let quota {
            let attributed = rootChildren.reduce(Int64(0)) { clampedAdd($0, $1.allocatedSize) }
            let unattributed = quota.usedBytes - attributed
            if unattributed > 0 {
                let id = CloudTargetID.nodeID(targetID: target.id, fileID: Self.unattributedFileID)
                rootChildren.append(FileNodeRecord(
                    id: id,
                    path: target.id + "/" + Self.unattributedName,
                    name: Self.unattributedName,
                    isDirectory: false,
                    isSymbolicLink: false,
                    allocatedSize: unattributed,
                    logicalSize: unattributed,
                    descendantFileCount: 0,
                    lastModified: nil,
                    fileIdentity: nil,
                    isPackage: false,
                    isAccessible: true,
                    isSelfAccessible: true,
                    isSynthetic: true,
                    isAutoSummarized: false
                ))
            }
        }

        let root = directoryRecord(
            id: target.id,
            path: target.id,
            name: target.displayName,
            children: rootChildren,
            fileIdentity: CloudTargetID.identity(providerID: providerID, fileID: rootFolderID),
            lastModified: nil,
            isSynthetic: false
        )
        childrenByNodeID[target.id] = rootChildren
        return FileTreeStore(root: root, childrenByID: childrenByNodeID)
    }

    /// Iteratively builds the records of `parentID`'s subtree (pre-order
    /// assigns display paths with sibling-name disambiguation, post-order
    /// rolls directory totals up), filling `childrenByNodeID` along the way.
    /// Returns the immediate children records. Iterative on explicit stacks:
    /// remote drives can nest deeper than the call stack tolerates.
    private func buildSubtrees(
        ofParent parentID: String?,
        rootIDs explicitRootIDs: [String]? = nil,
        parentPath: String,
        entries: [String: CloudFileEntry],
        childIDsByParent: [String: [String]],
        childrenByNodeID: inout [String: [FileNodeRecord]]
    ) -> [FileNodeRecord] {
        let topIDs = explicitRootIDs ?? childIDsByParent[parentID ?? ""] ?? []
        guard !topIDs.isEmpty else { return [] }

        struct Frame {
            let entryID: String
            let nodeID: String
            let path: String
            /// nil while descending; the built records land in
            /// childrenByNodeID and are read back when the frame pops.
            var childNodeIDs: [String]
        }

        var recordsByNodeID: [String: FileNodeRecord] = [:]
        var topRecords: [FileNodeRecord] = []

        let topLevel = disambiguatedNames(for: topIDs, entries: entries)
        // Two-phase stack: push (id, visit) to descend, (id, build) to emit.
        enum Phase { case visit, build }
        var stack: [(frame: Frame, phase: Phase)] = []
        for (id, name) in zip(topIDs, topLevel).reversed() {
            let frame = Frame(
                entryID: id,
                nodeID: CloudTargetID.nodeID(targetID: target.id, fileID: id),
                path: parentPath + "/" + name,
                childNodeIDs: []
            )
            stack.append((frame, .visit))
        }

        // Guards against parent cycles in provider data: a revisited entry is
        // skipped, breaking the loop (FileTreeStore would drop it anyway).
        var visitedEntryIDs: Set<String> = []

        while let (frame, phase) = stack.popLast() {
            guard let entry = entries[frame.entryID] else { continue }
            switch phase {
            case .visit:
                guard visitedEntryIDs.insert(frame.entryID).inserted else { continue }
                if entry.isFolder {
                    let childIDs = childIDsByParent[frame.entryID] ?? []
                    var visited = frame
                    visited.childNodeIDs = childIDs.map {
                        CloudTargetID.nodeID(targetID: target.id, fileID: $0)
                    }
                    stack.append((visited, .build))
                    let childNames = disambiguatedNames(for: childIDs, entries: entries)
                    for (childID, childName) in zip(childIDs, childNames).reversed() {
                        let childFrame = Frame(
                            entryID: childID,
                            nodeID: CloudTargetID.nodeID(targetID: target.id, fileID: childID),
                            path: frame.path + "/" + childName,
                            childNodeIDs: []
                        )
                        stack.append((childFrame, .visit))
                    }
                } else {
                    let record = fileRecord(entry: entry, nodeID: frame.nodeID, path: frame.path)
                    recordsByNodeID[frame.nodeID] = record
                }
            case .build:
                let children = frame.childNodeIDs.compactMap { recordsByNodeID[$0] }
                childrenByNodeID[frame.nodeID] = children
                let record = directoryRecord(
                    id: frame.nodeID,
                    path: frame.path,
                    name: (frame.path as NSString).lastPathComponent,
                    children: children,
                    fileIdentity: CloudTargetID.identity(providerID: providerID, fileID: entry.id),
                    lastModified: entry.modifiedAt,
                    isSynthetic: false
                )
                recordsByNodeID[frame.nodeID] = record
            }
        }

        for id in topIDs {
            let nodeID = CloudTargetID.nodeID(targetID: target.id, fileID: id)
            if let record = recordsByNodeID[nodeID] {
                topRecords.append(record)
            }
        }
        return topRecords
    }

    /// Sibling display names: a duplicate gains a short file-ID suffix
    /// before its extension ("report [a1b2c3].pdf"), keeping display paths
    /// unique enough for path-keyed consumers.
    private func disambiguatedNames(
        for ids: [String],
        entries: [String: CloudFileEntry]
    ) -> [String] {
        var used: Set<String> = []
        var names: [String] = []
        names.reserveCapacity(ids.count)
        for id in ids {
            guard let entry = entries[id] else {
                names.append(id)
                continue
            }
            var name = sanitizedName(entry.name)
            if !used.insert(name).inserted {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                let marker = String(entry.id.replacingOccurrences(of: "#", with: "").prefix(8))
                name = ext.isEmpty ? "\(base) [\(marker)]" : "\(base) [\(marker)].\(ext)"
                var attempt = 1
                while !used.insert(name).inserted {
                    name = ext.isEmpty
                        ? "\(base) [\(marker)-\(attempt)]"
                        : "\(base) [\(marker)-\(attempt)].\(ext)"
                    attempt += 1
                }
            }
            names.append(name)
        }
        return names
    }

    /// Provider names can contain "/", which would corrupt synthesized paths.
    private func sanitizedName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: ":")
    }

    private func fileRecord(entry: CloudFileEntry, nodeID: String, path: String) -> FileNodeRecord {
        FileNodeRecord(
            id: nodeID,
            path: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: entry.allocatedBytes,
            logicalSize: entry.logicalBytes ?? entry.allocatedBytes,
            descendantFileCount: 0,
            lastModified: entry.modifiedAt,
            fileIdentity: CloudTargetID.identity(providerID: providerID, fileID: entry.id),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func directoryRecord(
        id: String,
        path: String,
        name: String,
        children: [FileNodeRecord],
        fileIdentity: FileIdentity?,
        lastModified: Date?,
        isSynthetic: Bool
    ) -> FileNodeRecord {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var descendantFileCount = 0
        for child in children {
            allocatedSize = clampedAdd(allocatedSize, child.allocatedSize)
            logicalSize = clampedAdd(logicalSize, child.logicalSize)
            if child.isDirectory {
                descendantFileCount += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount += 1
            }
        }
        return FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: isSynthetic,
            isAutoSummarized: false
        )
    }

    // Display names of the synthetic buckets. English here; views localize
    // node names at display time (same convention as the local engine's
    // "System & Unattributed" node).
    static let sharedOrphanedName = "Shared & Orphaned"
    static let unattributedName = "Unattributed"
}

/// Saturating add, mirroring NeodiskKit's internal accumulation helper:
/// pathological provider sizes must clamp, never trap.
private func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs > 0 ? .max : .min) : sum
}
