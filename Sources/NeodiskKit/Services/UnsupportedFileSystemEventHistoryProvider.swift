//
//  UnsupportedFileSystemEventHistoryProvider.swift
//  Neodisk
//
//  `FileSystemEventHistoryProviding` for platforms without a persistent
//  change journal. Linux has no FSEvents equivalent — inotify and fanotify
//  only report changes while a watcher is running — so there is no
//  checkpoint to capture, and every rescan degrades to the full scan the
//  caller would have run anyway (`IncrementalFullScanReason.missingCheckpoint`).
//

#if !canImport(CoreServices)
struct UnsupportedFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint {
        throw FileSystemEventHistoryError.unsupportedPlatform
    }

    func history(
        since: FSEventsCheckpoint,
        through: FSEventsCheckpoint,
        target: ScanTarget
    ) async throws -> FileSystemEventHistory {
        throw FileSystemEventHistoryError.unsupportedPlatform
    }
}
#endif
