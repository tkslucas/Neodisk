import Foundation

public struct FileNodeRecord: Identifiable, Sendable {
    // A large scan holds millions of these: common fields inline in their smallest form, rare ones in one
    // optional side object.

    public let id: String
    public let name: String
    public let allocatedSize: Int64
    /// Inline, not in the side object: hard links make it differ from
    /// `allocatedSize` for most nodes on some disks (package-manager stores).
    public let unduplicatedAllocatedSize: Int64
    public let logicalSize: Int64
    /// `lastModified` as seconds since the reference date; NaN for nil.
    private let modifiedSeconds: Double
    /// A filesystem identity's device and inode (`Flags.hasDeviceInode`).
    private let device: UInt64
    private let inode: UInt64
    private let fileCount: UInt32
    private let links: UInt32
    private let flags: Flags
    private let extras: Extras?

    private struct Flags: OptionSet, Sendable {
        let rawValue: UInt16
        static let directory = Flags(rawValue: 1 << 0)
        static let symbolicLink = Flags(rawValue: 1 << 1)
        static let package = Flags(rawValue: 1 << 2)
        static let accessible = Flags(rawValue: 1 << 3)
        static let selfAccessible = Flags(rawValue: 1 << 4)
        static let synthetic = Flags(rawValue: 1 << 5)
        static let autoSummarized = Flags(rawValue: 1 << 6)
        static let dataless = Flags(rawValue: 1 << 7)
        static let hasDeviceInode = Flags(rawValue: 1 << 8)
    }

    /// The fields most records never set, boxed so they cost one pointer.
    private final class Extras: Sendable {
        let path: String?
        let resourceIdentifier: Data?
        let cloneInfo: CloneInfo?
        let cloudOnlyLogicalSize: Int64
        let summarizedClones: SummarizedClones?

        init(
            path: String?,
            resourceIdentifier: Data?,
            cloneInfo: CloneInfo?,
            cloudOnlyLogicalSize: Int64,
            summarizedClones: SummarizedClones?
        ) {
            self.path = path
            self.resourceIdentifier = resourceIdentifier
            self.cloneInfo = cloneInfo
            self.cloudOnlyLogicalSize = cloudOnlyLogicalSize
            self.summarizedClones = summarizedClones
        }
    }

    /// Stored as a string: URL construction dominates decoding million-node snapshots. Usually just the ID.
    public var path: String { extras?.path ?? id }
    public var isDirectory: Bool { flags.contains(.directory) }
    public var isSymbolicLink: Bool { flags.contains(.symbolicLink) }
    public var descendantFileCount: Int { Int(fileCount) }
    public var lastModified: Date? {
        modifiedSeconds.isNaN ? nil : Date(timeIntervalSinceReferenceDate: modifiedSeconds)
    }
    public var fileIdentity: FileIdentity? {
        if flags.contains(.hasDeviceInode) {
            return .fileSystem(device: device, inode: inode)
        }
        return extras?.resourceIdentifier.map { .resourceIdentifier($0) }
    }
    public var linkCount: UInt64 { UInt64(links) }
    public var isPackage: Bool { flags.contains(.package) }
    public var isAccessible: Bool { flags.contains(.accessible) }
    public var isSelfAccessible: Bool { flags.contains(.selfAccessible) }
    public var isSynthetic: Bool { flags.contains(.synthetic) }
    public var isAutoSummarized: Bool { flags.contains(.autoSummarized) }
    /// Content not downloaded (SF_DATALESS). Always false for directories, which use `cloudOnlyLogicalSize`.
    public var isDataless: Bool { flags.contains(.dataless) }
    /// For files, `logicalSize` when dataless; for directories, the descendant sum.
    public var cloudOnlyLogicalSize: Int64 { extras?.cloudOnlyLogicalSize ?? 0 }
    /// Captured only when blocks are shared (refCount > 1); drives clone dedup so totals track real usage.
    public var cloneInfo: CloneInfo? { extras?.cloneInfo }
    /// The clone families inside a summarized directory (package or
    /// auto-summarized folder), which has no file records to carry them.
    public var summarizedClones: SummarizedClones? { extras?.summarizedClones }

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
        cloneInfo: CloneInfo? = nil,
        summarizedClones: SummarizedClones? = nil
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
            cloneInfo: cloneInfo,
            summarizedClones: summarizedClones
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
        cloneInfo: CloneInfo? = nil,
        summarizedClones: SummarizedClones? = nil
    ) {
        let isDataless = isDataless && !isDirectory
        let cloudOnlyLogicalSize = cloudOnlyLogicalSize ?? (isDataless ? logicalSize : 0)
        let cloneInfo = isDirectory ? nil : cloneInfo
        let summarizedClones = isDirectory ? summarizedClones : nil

        self.id = id
        self.name = name
        self.allocatedSize = allocatedSize
        self.unduplicatedAllocatedSize = unduplicatedAllocatedSize ?? allocatedSize
        self.logicalSize = logicalSize
        modifiedSeconds = lastModified?.timeIntervalSinceReferenceDate ?? .nan
        fileCount = UInt32(clamping: descendantFileCount)
        links = UInt32(clamping: linkCount)

        var flags: Flags = []
        if isDirectory { flags.insert(.directory) }
        if isSymbolicLink { flags.insert(.symbolicLink) }
        if isPackage { flags.insert(.package) }
        if isAccessible { flags.insert(.accessible) }
        if isSelfAccessible { flags.insert(.selfAccessible) }
        if isSynthetic { flags.insert(.synthetic) }
        if isAutoSummarized { flags.insert(.autoSummarized) }
        if isDataless { flags.insert(.dataless) }
        var resourceIdentifier: Data?
        switch fileIdentity {
        case .fileSystem(let device, let inode):
            flags.insert(.hasDeviceInode)
            self.device = device
            self.inode = inode
        case .resourceIdentifier(let data):
            resourceIdentifier = data
            device = 0
            inode = 0
        case nil:
            device = 0
            inode = 0
        }
        self.flags = flags

        let pathOverride = path == id ? nil : path
        if pathOverride != nil || resourceIdentifier != nil || cloneInfo != nil || cloudOnlyLogicalSize != 0
            || summarizedClones != nil {
            extras = Extras(
                path: pathOverride,
                resourceIdentifier: resourceIdentifier,
                cloneInfo: cloneInfo,
                cloudOnlyLogicalSize: cloudOnlyLogicalSize,
                summarizedClones: summarizedClones
            )
        } else {
            extras = nil
        }
    }

    /// One definition shared by treemap and sunburst.
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
        isAccessible: Bool
    ) -> FileNodeRecord {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        var cloudOnlyLogicalSize: Int64 = 0
        var descendantFileCount = 0
        var childrenAreAccessible = true
        for child in children {
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
    /// Buggy drivers can report pathological sizes; summing them must clamp, never trap.
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
            cloneInfo: cloneInfo,
            summarizedClones: summarizedClones
        )
    }

    /// For the fine relist, so a shallow-relisted directory carries what a full scan would read. Totals stay
    /// from the baseline; the splice re-derives them (and `isAccessible`) wherever membership moved.
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
            cloneInfo: cloneInfo,
            summarizedClones: summarizedClones
        )
    }

    nonisolated func replacingAllocatedSize(
        _ allocatedSize: Int64,
        cloneInfo: CloneInfo?? = nil,
        summarizedClones: SummarizedClones?? = nil
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
            cloneInfo: cloneInfo ?? self.cloneInfo,
            summarizedClones: summarizedClones ?? self.summarizedClones
        )
    }

    /// Shared by traversal and relist so both reproduce a fresh scan's collapse to one node.
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
