// Chooses how a scan reads directories. On a local NTFS volume this process may read raw (an elevated process
// on Windows), one sequential pass over the master file table replaces a directory read per folder; anything
// else, or any inconsistency in the table, leaves the directory walk in charge. Either way the traversal,
// summaries, partial trees and progress are the walk's own, so the tree comes out the same.

import Foundation

nonisolated enum ScanEngineChoice: String, Sendable {
    case automatic = "auto"
    case walk
    case fileTable = "mft"

    /// `NEODISK_SCAN_ENGINE=walk|mft|auto`, for benchmarks; `diskscan --engine` sets it.
    static var requested: ScanEngineChoice {
        ProcessInfo.processInfo.environment["NEODISK_SCAN_ENGINE"].flatMap(ScanEngineChoice.init(rawValue:))
            ?? .automatic
    }
}

/// Keeps a volume's index registered for directory reads until the scan ends.
nonisolated final class VolumeIndexLease: Sendable {
    private let registrationID: Int

    init(registrationID: Int) {
        self.registrationID = registrationID
    }

    func end() {
        NTFSIndexRegistry.unregister(registrationID)
    }
}

nonisolated enum NTFSScanAccelerator {
    /// The bar's share for reading the file table. Reading C:\ (660 MB of records) took about as long as the
    /// traversal that follows it, measured on Windows 11.
    static let preparationSpan = 0.4

    /// The walk reports a link count of 1 for every file (directory listings carry none), so the index does the
    /// same: both engines then count every hard link, and their totals agree.
    static let reportsLinkCounts = false

    static var isAvailable: Bool {
        #if os(Windows)
        return ScanEngineChoice.requested != .walk
        #else
        return false
        #endif
    }

    /// Blocks while the file table is read. Nil means the walk reads the disk as usual. `progress` gets the
    /// fraction of the table read so far.
    static func prepare(
        targetPath: String,
        progress: (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> VolumeIndexLease? {
        #if os(Windows)
        guard isAvailable else { return nil }
        let start = ContinuousClock.now
        let reader: NTFSVolumeReader
        do {
            reader = try NTFSVolumeReader.open(volumeContaining: targetPath)
        } catch {
            ScanTiming.note("engine=walk reason=\(error)")
            return nil
        }
        // Reading the table costs the same whatever the target (about 1.3 s for C:\ on the test VM), and on
        // C:\Windows, a quarter of that volume, the engines already tie: the automatic choice reads it only for a
        // whole volume.
        if ScanEngineChoice.requested == .automatic, !isVolumeRoot(targetPath, mountPoint: reader.mountPoint) {
            ScanTiming.note("engine=walk reason=not-a-volume-root target=\(targetPath)")
            return nil
        }
        do {
            let (index, statistics) = try reader.readIndex(
                progress: { done, total in progress(total > 0 ? Double(done) / Double(total) : 1) },
                cancellationCheck: { if isCancelled() { throw CancellationError() } }
            )
            let rootPath = reader.mountPoint.replacingOccurrences(of: "\\", with: "/")
            let registrationID = NTFSIndexRegistry.register(index, rootPath: rootPath)
            guard NTFSIndexRegistry.directory(atPath: targetPath) != nil else {
                NTFSIndexRegistry.unregister(registrationID)
                ScanTiming.note("engine=walk reason=target-not-in-index target=\(targetPath)")
                return nil
            }
            ScanTiming.record(
                "scan.mft",
                ContinuousClock.now - start,
                detail: "records=\(index.recordCount) inUse=\(index.inUseRecordCount) names=\(index.linkCount) "
                    + String(format: "setupMs=%.1f readMs=%.1f parseMs=%.1f rereadMs=%.1f linkMs=%.1f ",
                             statistics.setupSeconds * 1000, statistics.readSeconds * 1000,
                             statistics.parseSeconds * 1000, statistics.rereadSeconds * 1000,
                             statistics.linkSeconds * 1000)
                    + "bytes=\(statistics.bytesRead) torn=\(statistics.tornRecordsReread) root=\(rootPath)"
            )
            return VolumeIndexLease(registrationID: registrationID)
        } catch {
            ScanTiming.note("engine=walk reason=\(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// `C:/` against `C:\`, case and separators aside.
    static func isVolumeRoot(_ path: String, mountPoint: String) -> Bool {
        func normalized(_ value: String) -> String {
            let slashed = value.replacingOccurrences(of: "\\", with: "/").lowercased()
            return slashed.hasSuffix("/") ? slashed : slashed + "/"
        }
        return normalized(path) == normalized(mountPoint)
    }
}
