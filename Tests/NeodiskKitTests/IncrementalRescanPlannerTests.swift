import Foundation
import Testing
@testable import NeodiskKit

@Suite("IncrementalRescanPlanner")
struct IncrementalRescanPlannerTests {
    private let target = makeTestTarget("/scan")
    private let options = ScanOptions()

    /// /scan
    /// ├── docs/            (dir)
    /// │   ├── report.txt
    /// │   └── nested/      (dir)
    /// │       └── deep.txt
    /// ├── apps/            (dir)
    /// │   └── Tool.app     (package leaf)
    /// ├── caches/          (dir, auto-summarized leaf)
    /// └── top.txt
    private func makeBaseline() -> FileTreeStore {
        let deep = makeTestFileNode(id: "/scan/docs/nested/deep.txt", name: "deep.txt", size: 5)
        let nested = makeTestDirectoryNode(id: "/scan/docs/nested", name: "nested", children: [deep])
        let report = makeTestFileNode(id: "/scan/docs/report.txt", name: "report.txt", size: 10)
        let docs = makeTestDirectoryNode(id: "/scan/docs", name: "docs", children: [report, nested])
        let package = makeTestDirectoryNode(id: "/scan/apps/Tool.app", name: "Tool.app", children: [], isPackage: true)
        let apps = makeTestDirectoryNode(id: "/scan/apps", name: "apps", children: [package])
        let caches = FileNodeRecord(
            id: "/scan/caches",
            url: URL(filePath: "/scan/caches", directoryHint: .isDirectory),
            name: "caches",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 9_000,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let top = makeTestFileNode(id: "/scan/top.txt", name: "top.txt", size: 1)
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: [docs, apps, caches, top])
        return FileTreeStore(root: root, childrenByID: [
            "/scan": [docs, apps, caches, top],
            "/scan/docs": [report, nested],
            "/scan/docs/nested": [deep],
            "/scan/apps": [package],
        ])
    }

    private func plan(
        _ events: [FileSystemChangeEvent],
        options: ScanOptions? = nil,
        behavior: ScanEngine.ScanBehavior = .standard,
        maxSubtrees: Int = IncrementalRescanPlanner.defaultMaxSubtrees,
        maxRelistDirectories: Int = IncrementalRescanPlanner.defaultMaxRelistDirectories
    ) -> IncrementalRescanPlan {
        let effectiveOptions = options ?? self.options
        return IncrementalRescanPlanner.plan(
            events: [FileSystemChangeEvent](events),
            target: target,
            baseline: makeBaseline(),
            options: effectiveOptions,
            behavior: behavior,
            exclusionMatcher: ScanExclusionMatcher(
                patterns: effectiveOptions.exclusionPatterns,
                rootPath: target.id,
                includeCloudStorage: true,
                cloudStorageRootPath: effectiveOptions.cloudStorageRootPath,
                iCloudDriveRootPath: effectiveOptions.iCloudDriveRootPath
            ),
            maxSubtrees: maxSubtrees,
            maxRelistDirectories: maxRelistDirectories
        )
    }

    private func event(
        _ path: String,
        _ flags: FileSystemEventFlags = [],
        id: UInt64 = 1
    ) -> FileSystemChangeEvent {
        FileSystemChangeEvent(path: path, eventID: id, flags: flags)
    }

    @Test func noEventsMeansNoChanges() {
        #expect(plan([]) == .noChanges)
    }

    @Test func fileEventRescansItsContainingDirectory() {
        let result = plan([event("/scan/docs/report.txt", [.itemCreated])])
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs"], deepRescanRootIDs: []))
    }

    @Test func directoryContentEventRescansTheDirectoryItself() {
        // No membership-change flags: the directory's own listing may have
        // shifted (e.g. attribute or coalesced content change).
        let result = plan([event("/scan/docs/nested", [.itemIsDirectory])])
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs/nested"], deepRescanRootIDs: []))
    }

    @Test func directoryRenameRescansTheParent() {
        let result = plan([event("/scan/docs/nested", [.itemIsDirectory, .itemRenamed])])
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs"], deepRescanRootIDs: []))
    }

    @Test func nestedCandidatesCollapseToTheirAncestor() {
        let result = plan([
            event("/scan/docs", [.mustScanSubdirectories]),
            event("/scan/docs/nested/deep.txt", [.itemCreated]),
        ])
        #expect(result == .relistDirectories(dirIDs: [], deepRescanRootIDs: ["/scan/docs"]))
    }

    @Test func unknownPathMapsToNearestMaterializedAncestor() {
        // /scan/docs/nested/brand-new/file.bin: neither the file nor its
        // parent exists in the baseline; the walk lands on nested.
        let result = plan([event("/scan/docs/nested/brand-new/file.bin", [.itemCreated])])
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs/nested"], deepRescanRootIDs: []))
    }

    @Test func eventInsidePackageRescansThePackageLeaf() {
        let result = plan([event("/scan/apps/Tool.app/Contents/Info.plist", [.itemCreated])])
        #expect(result == .relistDirectories(dirIDs: [], deepRescanRootIDs: ["/scan/apps/Tool.app"]))
    }

    @Test func eventInsideAutoSummarizedDirectoryRescansThatDirectory() {
        // Auto-summarized dirs are the most volatile
        // (caches, node_modules) — they re-summarize as a unit instead of
        // forcing a full scan.
        let result = plan([event("/scan/caches/tmp/blob", [.itemRemoved])])
        #expect(result == .relistDirectories(dirIDs: [], deepRescanRootIDs: ["/scan/caches"]))
    }

    @Test func changeDirectlyUnderScanRootRelistsTheRoot() {
        // A membership change directly under the scan root used to discard the
        // whole baseline; now it shallow-relists the root instead.
        let result = plan([event("/scan/top.txt", [.itemRemoved])])
        #expect(result == .relistDirectories(dirIDs: ["/scan"], deepRescanRootIDs: []))
    }

    @Test func eventOnScanRootRelistsTheRoot() {
        #expect(plan([event("/scan", [.itemIsDirectory, .itemRenamed])]) == .relistDirectories(dirIDs: ["/scan"], deepRescanRootIDs: []))
    }

    @Test func rootRelistCarriesDeepSubtreesFromTheSameWindow() {
        // A root membership change plus a deep change: relist the root AND
        // splice the mapped deep subtree in the same pass.
        let result = plan([
            event("/scan/top.txt", [.itemRemoved]),
            event("/scan/docs/report.txt", [.itemCreated]),
        ])
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs", "/scan"], deepRescanRootIDs: []))
    }

    @Test func hierarchicalCoalesceOnScanRootStillFullScans() {
        // mustScanSubdirectories on the root means the whole tree lost
        // granularity — only a full scan is trustworthy.
        #expect(plan([event("/scan", [.mustScanSubdirectories])]) == .fullScan(.changedScanRoot))
    }

    @Test func eventOutsideTargetFallsBackToFullScan() {
        #expect(plan([event("/elsewhere/file", [.itemCreated])]) == .fullScan(.eventOutsideTarget))
    }

    @Test(arguments: [
        (FileSystemEventFlags.userDropped, IncrementalFullScanReason.userDroppedEvents),
        (.kernelDropped, .kernelDroppedEvents),
        (.eventIDsWrapped, .eventIDsWrapped),
        (.rootChanged, .watchedRootChanged),
        (.volumeMounted, .nestedVolumeChanged),
        (.volumeUnmounted, .nestedVolumeChanged),
    ])
    func poisonFlagForcesFullScan(flag: FileSystemEventFlags, reason: IncrementalFullScanReason) {
        #expect(plan([event("/scan/docs/report.txt", flag)]) == .fullScan(reason))
    }

    @Test(arguments: [
        FileSystemEventFlags([.itemCreated, .itemIsHardLink]),
        [.itemRemoved, .itemIsHardLink],
        [.itemRemoved, .itemIsLastHardLink],
        [.itemIsHardLink],
    ])
    func hardLinkEventForcesFullScan(flags: FileSystemEventFlags) {
        // Dedup ownership is scan-wide; the journal names only the touched
        // link, so relisting its folder can double-count the shared bytes.
        #expect(plan([event("/scan/docs/report.txt", flags)]) == .fullScan(.hardLinkTopologyChanged))
    }

    @Test func hardLinkEventAfterOrdinaryEventsStillForcesFullScan() {
        let result = plan([
            event("/scan/docs/report.txt", [.itemCreated], id: 1),
            event("/scan/apps/link.bin", [.itemCreated, .itemIsHardLink], id: 2),
        ])
        #expect(result == .fullScan(.hardLinkTopologyChanged))
    }

    @Test func hardLinkEventsOutsideScannedContentAreIgnored() {
        // Paths the baseline never covered can't hold a counted link: hidden
        // (hidden files off) and excluded paths keep the incremental path.
        var excluding = ScanOptions()
        excluding.exclusionPatterns = ["docs/nested"]
        let result = plan([
            event("/scan/.cache/link.bin", [.itemCreated, .itemIsHardLink]),
            event("/scan/docs/nested/deep.txt", [.itemCreated, .itemIsHardLink]),
            event("/scan/docs/report.txt", [.itemCreated]),
        ], options: excluding)
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs"], deepRescanRootIDs: []))
    }

    @Test func hiddenPathsAreSkippedWhenHiddenFilesAreExcluded() {
        // .zsh_history-style churn directly under the scan root must not
        // force a full scan when the baseline never scanned hidden files.
        let result = plan([
            event("/scan/.history", [.itemCreated]),
            event("/scan/.config/settings", [.itemCreated]),
        ])
        #expect(result == .noChanges)
    }

    @Test func hiddenPathsCountWhenHiddenFilesAreIncluded() {
        var withHidden = ScanOptions()
        withHidden.includeHiddenFiles = true
        let result = plan([event("/scan/docs/nested/.secret", [.itemCreated])], options: withHidden)
        #expect(result == .relistDirectories(dirIDs: ["/scan/docs/nested"], deepRescanRootIDs: []))
    }

    @Test func excludedPathsAreSkipped() {
        var excluding = ScanOptions()
        excluding.exclusionPatterns = ["docs/nested"]
        let result = plan([event("/scan/docs/nested/deep.txt", [.itemCreated])], options: excluding)
        #expect(result == .noChanges)
    }

    @Test func tooManyDeepSubtreesFallsBackToFullScan() {
        // Two distinct deep (package/summarized) re-walk roots with a cap of one.
        let result = plan(
            [
                event("/scan/apps/Tool.app/x", [.itemCreated]),
                event("/scan/caches/blob", [.itemCreated]),
            ],
            maxSubtrees: 1
        )
        #expect(result == .fullScan(.tooManyChangedSubtrees))
    }

    @Test func tooManyRelistDirectoriesFallsBackToFullScan() {
        // Two distinct shallow-relist directories with a relist cap of one.
        let result = plan(
            [
                event("/scan/docs/report.txt", [.itemCreated]),
                event("/scan/apps/newfile.txt", [.itemCreated]),
            ],
            maxRelistDirectories: 1
        )
        #expect(result == .fullScan(.tooManyChangedSubtrees))
    }

    @Test func duplicateEventsPlanOnce() {
        let events = (0..<1_000).map {
            event("/scan/docs/report.txt", [.itemCreated], id: UInt64($0 + 1))
        }
        #expect(plan(events) == .relistDirectories(dirIDs: ["/scan/docs"], deepRescanRootIDs: []))
    }

    @Test func rootVolumePrivateVarEventsRescanTheirSubtree() {
        // A "/" scan's tree stores /private/var/... — nodes come from plain
        // traversal, not URL standardization — and the history provider now
        // surfaces events in that same qualified namespace. Regression: the
        // stripped form (/var/folders/...) missed the baseline, the ancestor
        // walk climbed to the root, and every Macintosh HD rescan degraded
        // to a full scan via .changedScanRoot.
        let rootTarget = makeTestTarget("/", kind: .volume)
        let folders = makeTestDirectoryNode(id: "/private/var/folders", name: "folders", children: [])
        let varDir = makeTestDirectoryNode(id: "/private/var", name: "var", children: [folders])
        let privateDir = makeTestDirectoryNode(id: "/private", name: "private", children: [varDir])
        let users = makeTestDirectoryNode(id: "/Users", name: "Users", children: [])
        let root = makeTestDirectoryNode(id: "/", name: "Root", children: [privateDir, users])
        let baseline = FileTreeStore(root: root, childrenByID: [
            "/": [privateDir, users],
            "/private": [varDir],
            "/private/var": [folders],
        ])
        var options = ScanOptions()
        options.includeHiddenFiles = true
        let result = IncrementalRescanPlanner.plan(
            events: [event("/private/var/folders/zz/T/scratch.tmp", [.itemCreated])],
            target: rootTarget,
            baseline: baseline,
            options: options,
            behavior: ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true),
            exclusionMatcher: ScanExclusionMatcher(
                patterns: [],
                rootPath: "/",
                includeCloudStorage: true,
                cloudStorageRootPath: ScanOptions.defaultCloudStorageRootPath,
                iCloudDriveRootPath: ScanOptions.defaultICloudDriveRootPath
            )
        )
        #expect(result == .relistDirectories(dirIDs: ["/private/var/folders"], deepRescanRootIDs: []))
    }

    @Test func startupVolumeInternalsAreSkippedUnderRootBehavior() {
        let rootTarget = makeTestTarget("/", kind: .volume)
        let sub = makeTestDirectoryNode(id: "/Applications", name: "Applications", children: [])
        let root = makeTestDirectoryNode(id: "/", name: "Root", children: [sub])
        let baseline = FileTreeStore(root: root, childrenByID: ["/": [sub]])
        var options = ScanOptions()
        options.includeHiddenFiles = true
        let result = IncrementalRescanPlanner.plan(
            events: [
                event("/Volumes/Backup/file", [.itemCreated]),
                event("/System/Volumes/Preboot/x", [.itemCreated]),
            ],
            target: rootTarget,
            baseline: baseline,
            options: options,
            behavior: ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true),
            exclusionMatcher: ScanExclusionMatcher(
                patterns: [],
                rootPath: "/",
                includeCloudStorage: true,
                cloudStorageRootPath: ScanOptions.defaultCloudStorageRootPath,
                iCloudDriveRootPath: ScanOptions.defaultICloudDriveRootPath
            )
        )
        #expect(result == .noChanges)
    }
}
