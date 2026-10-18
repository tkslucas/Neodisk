// Linux has no persistent change journal (inotify only sees changes while watching), so there's no
// checkpoint and every rescan falls back to a full scan (`missingCheckpoint`).

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
