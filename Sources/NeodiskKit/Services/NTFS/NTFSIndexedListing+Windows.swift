// Directory listings answered from a scan's file-table index, record for record what the disk reader would
// return for the same folder.

#if os(Windows)
import Foundation

extension BulkDirectoryReader {
    /// Nil when no registered index covers the directory; the caller reads the disk instead.
    static func indexedChildren(
        ofDirectory url: URL,
        cancellationCheck: CancellationCheck,
        onChild: (BulkDirectoryChild) throws -> Void
    ) throws -> Int? {
        guard !NTFSIndexRegistry.isEmpty,
              let (index, record) = NTFSIndexRegistry.directory(atPath: url.path) else {
            return nil
        }
        try cancellationCheck()
        var emittedCount = 0
        try index.forEachChild(of: record) { entry in
            try onChild(WindowsFileInfo.child(
                name: entry.name,
                attributes: entry.fileAttributes,
                reparseTag: entry.reparseTag,
                allocationSize: entry.allocationSize,
                endOfFile: entry.logicalSize,
                lastWriteTime: entry.lastWriteTime,
                fileID: entry.fileReference,
                volumeSerial: index.volumeSerial,
                linkCount: NTFSScanAccelerator.reportsLinkCounts ? UInt64(entry.linkCount) : 1
            ))
            emittedCount += 1
        }
        return emittedCount
    }
}
#endif
