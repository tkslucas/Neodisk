import Foundation
@testable import NeodiskKit

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1,
    cloneInfo: CloneInfo? = nil
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false,
        cloneInfo: cloneInfo
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    startedAt: Date = Date(),
    finishedAt: Date = Date()
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: startedAt,
        finishedAt: finishedAt,
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
}

/// Writes a small fixture file with plain POSIX calls, several times faster than `Data.write` on Linux,
/// for tests that need thousands of real files.
func writeFixtureFile(_ url: URL, bytes: [UInt8] = [0]) throws {
    let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    guard write(fd, bytes, bytes.count) == bytes.count else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
