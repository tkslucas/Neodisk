//
//  AtomicDirectoryParallelSummary.swift
//  Neodisk
//

import Foundation

extension AtomicDirectorySummarizer {
    /// Processes ONE directory level. Every child is reported to `sink`: files
    /// fold into the caller's partial/accumulator, subdirectories become new work
    /// items. Tries the getattrlistbulk reader first and, on any non-cancellation
    /// failure, restarts the level cleanly on the FileManager path — which owns
    /// the warning semantics for unreadable directories. Bulk reads a directory's
    /// full child list before folding any of it, so a fallback never double-counts.
    nonisolated static func processDirectoryLevel(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        bulkEnumerationEnabled: Bool,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        try cancellationCheck()

        if bulkEnumerationEnabled {
            do {
                try processDirectoryLevelUsingBulkReader(
                    item,
                    includeHiddenFiles: includeHiddenFiles,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    sink: sink
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch is AtomicSummaryJobCancelled {
                throw AtomicSummaryJobCancelled()
            } catch {
                // Fall through to the FileManager path, which owns the
                // warning semantics for unreadable directories.
            }
        }

        try processDirectoryLevelUsingFoundation(
            item,
            includeHiddenFiles: includeHiddenFiles,
            exclusionMatcher: exclusionMatcher,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellationCheck,
            sink: sink
        )
    }

    /// getattrlistbulk twin of the FileManager loop below: names and
    /// metadata arrive together, so there is no per-child resourceValues call.
    private nonisolated static func processDirectoryLevelUsingBulkReader(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        let bulkChildren = try BulkDirectoryReader.children(
            ofDirectory: item.url,
            category: .summary,
            cancellationCheck: cancellationCheck
        )
        let normalizedParentPath = item.url.standardizedFileURL.path
        // `item.url.path` (not standardized) so claim keys / recursion identity
        // match the rest of the tree; child path is `basePath + "/" + name`.
        let basePath = item.url.path

        for child in bulkChildren {
            try cancellationCheck()
            if !includeHiddenFiles && child.isHidden { continue }

            let childPath = ScanEngine.nodeChildPath(parentPath: basePath, childName: child.name)
            sink.onVisit(childPath)

            guard let childMetadata = child.metadata else {
                if let entryErrno = child.entryErrno {
                    sink.onWarning(
                        URL(filePath: childPath),
                        NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(entryErrno),
                            userInfo: [NSURLErrorKey: URL(filePath: childPath)]
                        )
                    )
                }
                continue
            }
            guard !exclusionMatcher.excludes(
                normalizedParentPath: normalizedParentPath,
                childName: child.name,
                isDirectory: childMetadata.isDirectory
            ) else {
                continue
            }

            sink.onAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                sink.onFile(childMetadata, childPath)
                continue
            }

            guard child.directoryMountStatus & MountBoundaryPolicy.mountPointFlag == 0 else {
                continue
            }

            sink.onSubdirectory(
                AtomicSummaryWorkItem(
                    url: URL(filePath: childPath, directoryHint: .isDirectory),
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }

    private nonisolated static func processDirectoryLevelUsingFoundation(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let childURLs: [URL]
        do {
            let enumerationResult = try ScanEngine.enumeratedDirectoryContents(
                url: item.url,
                keys: ScanMetadataLoader.atomicSummaryResourceKeys,
                options: options,
                cancellationCheck: cancellationCheck,
                makeEnumerator: { url, keys, options in
                    FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: options,
                        errorHandler: { childURL, error in
                            sink.onWarning(childURL, error)
                            return true
                        }
                    )
                }
            )
            childURLs = enumerationResult.urls
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sink.onWarning(item.url, error)
            return
        }

        for childURL in childURLs {
            try cancellationCheck()
            sink.onVisit(childURL.path)

            let hintedIsDirectory = childURL.hasDirectoryPath
            guard !exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
                childMetadata = metadataLoader.metadata(for: childURL, prefetchedResourceValues: values)
            } catch {
                sink.onWarning(childURL, error)
                continue
            }

            guard !exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) else {
                continue
            }

            sink.onAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                sink.onFile(childMetadata, childURL.path)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            sink.onSubdirectory(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }
}
