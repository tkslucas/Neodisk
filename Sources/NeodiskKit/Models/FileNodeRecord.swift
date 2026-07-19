//
//  FileNodeRecord.swift
//  Neodisk
//

import Foundation

public struct FileNodeRecord: Identifiable, Sendable {
    public let id: String
    /// Absolute filesystem path. The record stores the path string rather
    /// than a URL: URL construction measurably dominates decoding
    /// million-node snapshots, and most consumers only need the string.
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let allocatedSize: Int64
    public let unduplicatedAllocatedSize: Int64
    public let logicalSize: Int64
    public let descendantFileCount: Int
    public let lastModified: Date?
    public let fileIdentity: FileIdentity?
    public let linkCount: UInt64
    public let isPackage: Bool
    public let isAccessible: Bool
    public let isSelfAccessible: Bool
    public let isSynthetic: Bool
    public let isAutoSummarized: Bool
    /// File exists in a cloud drive (iCloud/File Provider) but its content
    /// is not downloaded: full logical size, ~0 bytes on disk (SF_DATALESS).
    /// Always false for directories — a directory's cloud share is carried
    /// by `cloudOnlyLogicalSize` instead.
    public let isDataless: Bool
    /// Bytes that live only in the cloud below this node: for files,
    /// `logicalSize` when dataless, else 0; for directories, the descendant
    /// sum. Display weight = `allocatedSize + cloudOnlyLogicalSize` when the
    /// cloud-only toggle is on.
    public let cloudOnlyLogicalSize: Int64
    /// APFS clone-family membership, captured only when the kernel reports
    /// the file shares blocks with others (refCount > 1). Drives clone
    /// deduplication so scanned totals track real disk usage.
    public let cloneInfo: CloneInfo?

    /// URL form of `path`. Computed on demand — see `path`.
    public nonisolated var url: URL {
        URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// Path extension without URL construction, matching
    /// `URL.pathExtension` semantics via `NSString.pathExtension`.
    public nonisolated var pathExtension: String {
        (path as NSString).pathExtension
    }

    public nonisolated init(
        id: String,
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool,
        isDataless: Bool = false,
        cloudOnlyLogicalSize: Int64? = nil,
        cloneInfo: CloneInfo? = nil
    ) {
        self.init(
            id: id,
            path: url.path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo
        )
    }

    public nonisolated init(
        id: String,
        path: String,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        unduplicatedAllocatedSize: Int64? = nil,
        logicalSize: Int64,
        descendantFileCount: Int,
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        isSelfAccessible: Bool,
        isSynthetic: Bool,
        isAutoSummarized: Bool,
        isDataless: Bool = false,
        cloudOnlyLogicalSize: Int64? = nil,
        cloneInfo: CloneInfo? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedSize = allocatedSize
        self.unduplicatedAllocatedSize = unduplicatedAllocatedSize ?? allocatedSize
        self.logicalSize = logicalSize
        self.descendantFileCount = descendantFileCount
        self.lastModified = lastModified
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.isPackage = isPackage
        self.isAccessible = isAccessible
        self.isSelfAccessible = isSelfAccessible
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
        self.isDataless = isDataless && !isDirectory
        self.cloudOnlyLogicalSize = cloudOnlyLogicalSize
            ?? (isDataless && !isDirectory ? logicalSize : 0)
        self.cloneInfo = isDirectory ? nil : cloneInfo
    }

    /// Weight used by the visualizations: on-disk bytes, plus the bytes that
    /// live only in the cloud when the cloud-only toggle is on. One
    /// definition shared by treemap and sunburst.
    public nonisolated func displayWeight(includingCloudOnly: Bool) -> Int64 {
        includingCloudOnly
            ? allocatedSize.addingClamped(cloudOnlyLogicalSize)
            : allocatedSize
    }

    nonisolated var itemKind: String {
        if isSynthetic {
            return "System Data"
        }
        if isAutoSummarized {
            return "Summarized"
        }
        if isSymbolicLink {
            return "Alias"
        }
        if isPackage {
            return "Package"
        }
        return isDirectory ? "Folder" : "File"
    }

    public nonisolated var supportsFileActions: Bool {
        !isSynthetic
    }

    public nonisolated static func directory(
        id: String,
        url: URL,
        name: String,
        children: [FileNodeRecord],
        lastModified: Date?,
        fileIdentity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        isPackage: Bool,
        isAccessible: Bool,
        childrenAreSorted: Bool = false
    ) -> FileNodeRecord {
        let sortedChildren = childrenAreSorted ? children : FileTreeStore.sortedChildren(children)
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var cloudOnlyLogicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true
        for child in sortedChildren {
            allocatedSize = allocatedSize.addingClamped(child.allocatedSize)
            logicalSize = logicalSize.addingClamped(child.logicalSize)
            cloudOnlyLogicalSize = cloudOnlyLogicalSize.addingClamped(child.cloudOnlyLogicalSize)
            childrenAreAccessible = childrenAreAccessible && child.isAccessible
            if child.isDirectory {
                descendantFileCount += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                descendantFileCount += 1
            }
        }
        let isFullyAccessible = isAccessible && childrenAreAccessible

        return FileNodeRecord(
            id: id,
            url: url,
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isFullyAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize
        )
    }
}

extension Int64 {
    /// Saturating addition for file-size accumulation. Buggy filesystem
    /// drivers can report pathological sizes; summing those must degrade to
    /// a clamped number, never trap the whole app.
    public nonisolated func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

extension FileNodeRecord {
    var secondaryStatusText: String? {
        if isSynthetic {
            return "Estimated from volume usage"
        }
        if isAutoSummarized {
            return "Summarized (\(descendantFileCount) files)"
        }
        if !isAccessible {
            return "Limited access"
        }
        return nil
    }

    var accessDescription: String {
        if isSynthetic {
            return "Estimated"
        }
        return isAccessible ? "Readable" : "Limited"
    }

}

extension FileNodeRecord {
    /// The same record with a refreshed modification date — used by the root
    /// relist to move the scan root's own mtime without disturbing its totals.
    nonisolated func replacingLastModified(_ lastModified: Date?) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo
        )
    }

    /// The same directory record with its own-metadata fields refreshed from a
    /// fresh read — used by the fine relist so a shallow-relisted directory
    /// carries the identity/linkCount/package/accessibility/mtime a full scan
    /// would read, not just its baseline copy. Totals are intentionally kept
    /// from the baseline: the splice re-derives them for any directory whose
    /// membership moved, and a directory whose membership did not move keeps its
    /// correct baseline totals. `isAccessible` (a self ∧ children rollup) is set
    /// from the refreshed self-accessibility combined with the baseline's
    /// children-accessibility; the splice recomputes it from real spliced
    /// children for every directory whose membership moved, which is the only
    /// case in which children-accessibility can differ from the baseline.
    nonisolated func refreshingOwnMetadata(_ metadata: NodeMetadata) -> FileNodeRecord {
        let childrenAccessible = isSelfAccessible ? isAccessible : true
        return FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: metadata.lastModified,
            fileIdentity: metadata.fileIdentity,
            linkCount: metadata.linkCount,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable && childrenAccessible,
            isSelfAccessible: metadata.isReadable,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo
        )
    }

    nonisolated func replacingAllocatedSize(
        _ allocatedSize: Int64,
        cloneInfo: CloneInfo?? = nil
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo ?? self.cloneInfo
        )
    }

    /// The childless inaccessible node a full scan produces for an unreadable
    /// item: size 0, both accessibility flags false. Shared by the traversal
    /// (a directory whose enumeration failed, or an unclassifiable child) and
    /// the incremental relist (an unreadable child spliced inline without a
    /// subtree walk), so both reproduce a fresh scan's collapse to one node.
    nonisolated static func inaccessible(path: String, isDirectory: Bool) -> FileNodeRecord {
        let url = URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        return FileNodeRecord(
            id: path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }
}
