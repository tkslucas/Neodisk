//
//  BulkDirectoryReader.swift
//  Neodisk
//
//  One getattrlistbulk(2) loop returns every child of a directory together
//  with the metadata the scanner needs (type, sizes, mod date, link count,
//  inode, flags, readability) — replacing the FileManager enumerator plus a
//  per-child resourceValues() call, i.e. one syscall per ~few-hundred entries
//  instead of several syscalls per entry. Read-only by construction: the only
//  operations are open(O_RDONLY), getattrlistbulk, an exotic-filesystem-only
//  fstat fallback, and close.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A child entry produced by `BulkDirectoryReader`.
nonisolated struct BulkDirectoryChild: Sendable {
    let name: String
    /// nil when the kernel reported a per-entry error instead of attributes.
    let metadata: NodeMetadata?
    /// errno reported via ATTR_CMN_ERROR for this entry, if any.
    let entryErrno: Int32?
    /// Hidden by dot-name, UF_HIDDEN flag, or the Finder invisible bit —
    /// mirrors FileManager's `.skipsHiddenFiles` classification.
    let isHidden: Bool
    /// The child's device from ATTR_CMN_DEVID. This is intentionally kept
    /// separate from the selectively persisted FileIdentity: mount-boundary
    /// decisions need it for every directory, while small ordinary files
    /// still avoid carrying identity in snapshots.
    let deviceID: UInt64?
    /// ATTR_DIR_MOUNTSTATUS for directories; zero when the filesystem omits
    /// the attribute or for non-directories.
    let directoryMountStatus: UInt32
}

nonisolated enum BulkDirectoryReadError: Error {
    /// open(2) on the directory failed (errno attached).
    case openFailed(Int32)
    /// getattrlistbulk(2) failed (errno attached); caller should fall back.
    case bulkListFailed(Int32)
}

nonisolated enum BulkDirectoryReader {
    /// Mutable getattrlistbulk storage. A context must never be used by two
    /// reads concurrently; scanner I/O workers and `ContextPool` enforce that
    /// ownership explicitly instead of relying on Swift tasks staying on one
    /// OS thread.
    final class Context: @unchecked Sendable {
        static let bufferSize = 16 * 1024
        fileprivate let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: 16
        )

        deinit {
            buffer.deallocate()
        }
    }

    /// Compatibility callers (atomic walkers and tests) borrow from this
    /// bounded pool. The full traversal uses worker-owned contexts directly.
    final class ContextPool: @unchecked Sendable {
        private let condition = NSCondition()
        private let maximumContextCount: Int
        private var available: [Context] = []
        private var allocatedContextCount = 0

        init(maximumContextCount: Int) {
            self.maximumContextCount = max(1, maximumContextCount)
        }

        var contextCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return allocatedContextCount
        }

        func withContext<Result>(
            cancellationCheck: CancellationCheck,
            _ body: (Context) throws -> Result
        ) throws -> Result {
            let context = try acquire(cancellationCheck: cancellationCheck)
            defer { release(context) }
            return try body(context)
        }

        private func acquire(cancellationCheck: CancellationCheck) throws -> Context {
            condition.lock()
            while true {
                if let context = available.popLast() {
                    condition.unlock()
                    return context
                }
                if allocatedContextCount < maximumContextCount {
                    allocatedContextCount += 1
                    condition.unlock()
                    return Context()
                }

                condition.unlock()
                try cancellationCheck()
                condition.lock()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            }
        }

        private func release(_ context: Context) {
            condition.lock()
            available.append(context)
            condition.signal()
            condition.unlock()
        }
    }

    private static let compatibilityContextPool = ContextPool(maximumContextCount: 48)

    /// Reads all children of `url` in getattrlistbulk batches.
    /// Throws on any failure — callers fall back to the FileManager path so
    /// exotic volumes and permission errors keep their existing semantics.
    static func children(
        ofDirectory url: URL,
        category: ScanSyscallCategory = .other,
        cancellationCheck: CancellationCheck
    ) throws -> [BulkDirectoryChild] {
        try compatibilityContextPool.withContext(cancellationCheck: cancellationCheck) { context in
            var children: [BulkDirectoryChild] = []
            _ = try readChildren(
                ofDirectory: url,
                using: context,
                category: category,
                cancellationCheck: cancellationCheck
            ) { child in
                children.append(child)
            }
            return children
        }
    }

    #if canImport(Darwin)
    /// Streams decoded records to `onChild`, avoiding the complete
    /// `[BulkDirectoryChild]` allocation on the scan hot path. The callback is
    /// synchronous and executes while `context` is exclusively borrowed.
    @discardableResult
    static func readChildren(
        ofDirectory url: URL,
        using context: Context,
        category: ScanSyscallCategory = .traversal,
        cancellationCheck: CancellationCheck,
        onChild: (BulkDirectoryChild) throws -> Void
    ) throws -> Int {
        try ProtectedContainers.withReadSlot(forDirectory: url.path) {
            readSlots.wait()
            defer { readSlots.signal() }
            return try readChildrenUngated(
                ofDirectory: url,
                using: context,
                category: category,
                cancellationCheck: cancellationCheck,
                onChild: onChild
            )
        }
    }

    /// Directory reads in the kernel at once, across traversal, probes and
    /// summaries. A machine kept fully busy starves the system daemons that
    /// vouch for app-container access until their five-second timeout (C
    /// walks on the M4: 8 threads beside a 1-thread container walk stalled it
    /// in 4 of 6 runs, 6 + 2 threads in 0 of 6), and past ~8 readers
    /// getattrlistbulk only contends with itself. `~`, interleaved: on the
    /// 10-core M4, 8 slots 13.7 s median with 2 of 6 runs stalled up to 17.4 s,
    /// 7 slots 13.8 s with none (worst 14.2 s), 6 slots 14.4 s; on the 8-core
    /// M1, 7 and 8 slots tie (8.2 s), 5 slots 8.7 s.
    /// `NEODISK_SCAN_READ_SLOTS=<n>` overrides it.
    static let readSlotCount: Int = ProcessInfo.processInfo.environment["NEODISK_SCAN_READ_SLOTS"]
        .flatMap(Int.init).map { max(1, $0) }
        ?? min(7, max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
    private static let readSlots = DispatchSemaphore(value: readSlotCount)

    private static func readChildrenUngated(
        ofDirectory url: URL,
        using context: Context,
        category: ScanSyscallCategory,
        cancellationCheck: CancellationCheck,
        onChild: (BulkDirectoryChild) throws -> Void
    ) throws -> Int {
        try cancellationCheck()

        // Never trigger downloads of dataless (cloud-evicted) files while
        // enumerating. Thread-scoped and cheap; cooperative-pool threads are
        // reused, so keep re-asserting rather than assuming a prior call.
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )

        let readSince = ScanProfile.now()
        let readToken = category == .traversal ? ScanProfile.started(.ioRead, url.path) : 0
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let openErrno = errno
            ScanProfile.finish(readToken)
            throw BulkDirectoryReadError.openFailed(openErrno)
        }
        ScanProfile.end(.ioOpen, since: readSince)
        var syscallNanoseconds: UInt64 = 0
        var parseNanoseconds: UInt64 = 0
        var entriesRead = 0
        defer {
            close(fd)
            ScanProfile.finish(readToken)
            ScanProfile.noteSlowRead(
                path: "\(category) \(url.path)",
                since: readSince,
                syscallNanoseconds: syscallNanoseconds,
                parseNanoseconds: parseNanoseconds,
                entries: entriesRead
            )
        }

        // Diagnostic syscall accounting (NEODISK_SCAN_SYSCALLS). Recorded once
        // per successfully opened directory; no-op when the flag is off.
        var bulkCallCount = 0
        var emittedForTally = 0
        defer {
            ScanSyscallTally.recordBulkDirectory(category, bulkCalls: bulkCallCount, entries: emittedForTally)
        }

        var commonAttributes: UInt32 = ATTR_CMN_RETURNED_ATTRS
        commonAttributes |= RequestedAttributes.error
        commonAttributes |= RequestedAttributes.name
        commonAttributes |= RequestedAttributes.deviceID
        commonAttributes |= RequestedAttributes.objectType
        commonAttributes |= RequestedAttributes.modificationTime
        commonAttributes |= RequestedAttributes.finderInfo
        commonAttributes |= RequestedAttributes.flags
        commonAttributes |= RequestedAttributes.userAccess
        commonAttributes |= RequestedAttributes.fileID
        var fileAttributes: UInt32 = RequestedAttributes.fileLinkCount
        fileAttributes |= RequestedAttributes.fileAllocatedSize
        fileAttributes |= RequestedAttributes.fileDataLength
        let directoryAttributes = RequestedAttributes.directoryMountStatus

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = commonAttributes
        request.dirattr = directoryAttributes
        request.fileattr = fileAttributes
        // With FSOPT_ATTR_CMN_EXTENDED the forkattr field carries the
        // common-extended attributes (we request no real fork attributes):
        // clone-family identity, so shared-block files can be deduplicated.
        // Filesystems without clone tracking simply omit them per entry.
        request.forkattr = RequestedAttributes.cloneID | RequestedAttributes.cloneRefCount

        var emittedCount = 0
        var fallbackDirectoryDevice: UInt64?
        var didProbeFallbackDirectoryDevice = false
        while true {
            try cancellationCheck()
            bulkCallCount += 1
            let bulkSince = ScanProfile.now()
            let batchCount = getattrlistbulk(
                fd,
                &request,
                context.buffer,
                Context.bufferSize,
                UInt64(FSOPT_ATTR_CMN_EXTENDED)
            )
            if batchCount < 0 {
                throw BulkDirectoryReadError.bulkListFailed(errno)
            }
            ScanProfile.end(batchCount > 0 ? .ioBulk : .ioBulkEnd, since: bulkSince)
            if ScanProfile.isEnabled {
                syscallNanoseconds &+= ScanProfile.now() &- bulkSince
                entriesRead += Int(max(batchCount, 0))
            }
            let parseSince = ScanProfile.now()
            defer {
                if ScanProfile.isEnabled { parseNanoseconds &+= ScanProfile.now() &- parseSince }
            }
            if batchCount == 0 {
                if category == .traversal {
                    ScanProfile.add(.entries, count: emittedCount)
                }
                emittedForTally = emittedCount
                return emittedCount
            }

            var entry = context.buffer
            for _ in 0..<batchCount {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                if let child = parseEntry(
                    at: entry,
                    directoryFD: fd,
                    resolvesClonePrivateSize: category == .traversal || category == .probe,
                    fallbackDirectoryDevice: &fallbackDirectoryDevice,
                    didProbeFallbackDirectoryDevice: &didProbeFallbackDirectoryDevice
                ) {
                    try onChild(child)
                    emittedCount += 1
                }
                entry += entryLength
            }
        }
    }

    /// UInt32 views of the sys/attr.h request bits (they import into Swift
    /// with mixed signedness; attrgroup_t is UInt32).
    static let verifiesClonePrivateSizes = ProcessInfo.processInfo.environment["NEODISK_SCAN_VERIFY_CLONES"] == "1"

    private static func familyMemberPrivateSize(name: UnsafeMutableRawPointer?, directoryFD: Int32) -> Int64? {
        guard verifiesClonePrivateSizes, let name else { return 0 }
        let size = privateSize(of: name, inDirectory: directoryFD)
        if size != 0 {
            ScanProfile.add(.clonePrivateSizeMismatch)
            ScanTiming.note(
                "clone private size \(size.map(String.init) ?? "unknown") for "
                + String(cString: name.assumingMemoryBound(to: CChar.self))
            )
        }
        return size
    }

    /// One getattrlistat(2) for ATTR_CMNEXT_PRIVATESIZE of `name` inside the
    /// open directory; nil when the kernel won't say.
    private static func privateSize(of name: UnsafeMutableRawPointer, inDirectory directoryFD: Int32) -> Int64? {
        let since = ScanProfile.now()
        defer { ScanProfile.end(.clonePrivateSize, since: since) }
        ScanSyscallTally.recordCloneGetattr(count: 1)
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = UInt32(bitPattern: ATTR_CMNEXT_PRIVATESIZE)
        // returned length (u32) + off_t, padded to 4-byte boundaries.
        var buffer: (UInt64, UInt64) = (0, 0)
        let status = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlistat(
                directoryFD,
                name.assumingMemoryBound(to: CChar.self),
                &request,
                raw.baseAddress,
                raw.count,
                UInt(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
            )
        }
        guard status == 0 else { return nil }
        return withUnsafeBytes(of: &buffer) { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 12 else { return nil }
            return max(raw.loadUnaligned(fromByteOffset: 4, as: Int64.self), 0)
        }
    }

    private enum RequestedAttributes {
        static let error = UInt32(bitPattern: ATTR_CMN_ERROR)
        static let name = UInt32(bitPattern: ATTR_CMN_NAME)
        static let deviceID = UInt32(bitPattern: ATTR_CMN_DEVID)
        static let objectType = UInt32(bitPattern: ATTR_CMN_OBJTYPE)
        static let modificationTime = UInt32(bitPattern: ATTR_CMN_MODTIME)
        static let finderInfo = UInt32(bitPattern: ATTR_CMN_FNDRINFO)
        static let flags = UInt32(bitPattern: ATTR_CMN_FLAGS)
        static let userAccess = UInt32(bitPattern: ATTR_CMN_USERACCESS)
        static let fileID = UInt32(bitPattern: ATTR_CMN_FILEID)
        static let fileLinkCount = UInt32(bitPattern: ATTR_FILE_LINKCOUNT)
        static let fileAllocatedSize = UInt32(bitPattern: ATTR_FILE_ALLOCSIZE)
        static let fileDataLength = UInt32(bitPattern: ATTR_FILE_DATALENGTH)
        static let directoryMountStatus = UInt32(bitPattern: ATTR_DIR_MOUNTSTATUS)
        // Common-extended attributes ride the forkattr field under
        // FSOPT_ATTR_CMN_EXTENDED (sys/attr.h).
        static let cloneID = UInt32(bitPattern: ATTR_CMNEXT_CLONEID)
        static let cloneRefCount = UInt32(bitPattern: ATTR_CMNEXT_CLONE_REFCNT)
    }

    // MARK: - Entry parsing

    /// Attribute buffer layout (man getattrlist): each entry starts with a
    /// u32 total length, then the requested attributes packed in ascending
    /// attribute-bit order on 4-byte boundaries. Two special cases:
    /// ATTR_CMN_RETURNED_ATTRS is always first, and ATTR_CMN_ERROR — when
    /// present — is packed immediately after it, before everything else.
    private static func parseEntry(
        at entryStart: UnsafeMutableRawPointer,
        directoryFD: Int32,
        resolvesClonePrivateSize: Bool,
        fallbackDirectoryDevice: inout UInt64?,
        didProbeFallbackDirectoryDevice: inout Bool
    ) -> BulkDirectoryChild? {
        var field = entryStart + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let directory = returned.dirattr
        let file = returned.fileattr
        // Common-extended attributes are reported through forkattr — see
        // the request setup.
        let commonExtended = returned.forkattr

        var entryErrno: Int32?
        if common & RequestedAttributes.error != 0 {
            entryErrno = Int32(bitPattern: field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size
        }

        var name: String?
        var nameStart: UnsafeMutableRawPointer?
        if common & RequestedAttributes.name != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            if reference.attr_length > 0 {
                let start = field + Int(reference.attr_dataoffset)
                nameStart = start
                name = String(cString: start.assumingMemoryBound(to: CChar.self))
            }
            field += MemoryLayout<attrreference_t>.size
        }

        var reportedDevice: UInt64?
        if common & RequestedAttributes.deviceID != 0 {
            let device = field.loadUnaligned(as: dev_t.self)
            reportedDevice = UInt64(bitPattern: Int64(device))
            field += MemoryLayout<dev_t>.size
        }

        var objectType: fsobj_type_t = 0
        if common & RequestedAttributes.objectType != 0 {
            objectType = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }

        var lastModified: Date?
        if common & RequestedAttributes.modificationTime != 0 {
            let modified = field.loadUnaligned(as: timespec.self)
            lastModified = Date(
                timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000
            )
            field += MemoryLayout<timespec>.size
        }

        var finderFlags: UInt16 = 0
        if common & RequestedAttributes.finderInfo != 0 {
            // FileInfo and FolderInfo both keep finderFlags (big-endian) at
            // byte offset 8 of the 32-byte Finder info blob.
            finderFlags = UInt16(bigEndian: (field + 8).loadUnaligned(as: UInt16.self))
            field += 32
        }

        var bsdFlags: UInt32 = 0
        if common & RequestedAttributes.flags != 0 {
            bsdFlags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var userAccess: UInt32?
        if common & RequestedAttributes.userAccess != 0 {
            userAccess = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var inode: UInt64 = 0
        if common & RequestedAttributes.fileID != 0 {
            inode = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        var directoryMountStatus: UInt32 = 0
        if directory & RequestedAttributes.directoryMountStatus != 0 {
            directoryMountStatus = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var linkCount: UInt64 = 1
        if file & RequestedAttributes.fileLinkCount != 0 {
            linkCount = UInt64(max(field.loadUnaligned(as: UInt32.self), 1))
            field += MemoryLayout<UInt32>.size
        }

        var allocatedSize: Int64?
        if file & RequestedAttributes.fileAllocatedSize != 0 {
            allocatedSize = max(field.loadUnaligned(as: off_t.self), 0)
            field += MemoryLayout<off_t>.size
        }

        var logicalSize: Int64 = 0
        if file & RequestedAttributes.fileDataLength != 0 {
            logicalSize = max(field.loadUnaligned(as: off_t.self), 0)
            field += MemoryLayout<off_t>.size
        }

        // Extended attributes pack after the file group.
        var cloneID: UInt64?
        if commonExtended & RequestedAttributes.cloneID != 0 {
            cloneID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }
        var cloneRefCount: UInt32 = 1
        if commonExtended & RequestedAttributes.cloneRefCount != 0 {
            cloneRefCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        guard let name else { return nil }

        if let entryErrno {
            return BulkDirectoryChild(
                name: name,
                metadata: nil,
                entryErrno: entryErrno,
                isHidden: isHiddenName(name),
                deviceID: reportedDevice,
                directoryMountStatus: directoryMountStatus
            )
        }

        let isDirectory = objectType == UInt32(VDIR.rawValue)
        let isSymbolicLink = objectType == UInt32(VLNK.rawValue)
        let isHidden = isHiddenName(name)
            || bsdFlags & UInt32(UF_HIDDEN) != 0
            || finderFlags & FinderFlags.isInvisible != 0

        let isPackage = isDirectory && (
            finderFlags & FinderFlags.hasBundle != 0
                || PackageExtensionCatalog.shared.isPackageName(name)
        )

        // Match the URLResourceValues-based loader: readable unless the
        // kernel-computed user access says otherwise; directories carry no
        // sizes of their own (their totals come from children).
        let isReadable = userAccess.map { $0 & UInt32(R_OK) != 0 } ?? true
        let fileLogicalSize = isDirectory ? 0 : logicalSize
        let fileAllocatedSize = isDirectory ? 0 : (allocatedSize ?? logicalSize)
        let device = reportedDevice ?? fallbackDevice(
            directoryFD: directoryFD,
            cachedDevice: &fallbackDirectoryDevice,
            didProbe: &didProbeFallbackDirectoryDevice
        ) ?? 0
        // Identity feeds hard-link deduplication (multi-link files) and
        // rename detection in scan diffs (directories and files big enough
        // to matter — see ScanSizeBaseline.renameTrackingMinimumFileSize).
        // The device+inode pair is already in the bulk attribute buffer, so
        // capturing it costs no extra syscalls, only the ~17 bytes it adds
        // to each identity-bearing node in persisted snapshots — which is
        // why small single-link files skip it.
        let capturesIdentity = !isSymbolicLink && (
            isDirectory
                || linkCount > 1
                || fileAllocatedSize >= ScanSizeBaseline.renameTrackingMinimumFileSize
        )
        let fileIdentity: FileIdentity? = capturesIdentity
            ? .fileSystem(device: device, inode: inode)
            : nil
        // Clone-family membership matters only when blocks are actually
        // shared (refCount > 1), so the non-cloned majority carries nothing.
        // A clone family member's private (unshared) size is 0: files share a
        // clone ID only while their data is identical, and any write to one
        // gives it a new ID with a reference count of 1, taking it out of the
        // family (checked: overwrite, truncate and hole punch all do; xattrs
        // don't touch data). ATTR_CMNEXT_PRIVATESIZE agreed on every one of
        // 511k members on two Macs' whole disks, so traversal records 0
        // instead of one getattrlistat per member (~1.2 s of a home-folder
        // scan). NEODISK_SCAN_VERIFY_CLONES=1 reads it anyway and counts
        // disagreements.
        let cloneInfo: CloneInfo? = !isDirectory && !isSymbolicLink
            && cloneRefCount > 1
            ? cloneID.map {
                CloneInfo(
                    device: device,
                    cloneID: $0,
                    refCount: cloneRefCount,
                    privateSize: resolvesClonePrivateSize
                        ? familyMemberPrivateSize(name: nameStart, directoryFD: directoryFD)
                        : nil
                )
            }
            : nil

        return BulkDirectoryChild(
            name: name,
            metadata: NodeMetadata(
                isDirectory: isDirectory,
                isPackage: isPackage,
                isSymbolicLink: isSymbolicLink,
                logicalSize: fileLogicalSize,
                allocatedSize: fileAllocatedSize,
                lastModified: lastModified,
                isReadable: isReadable,
                volumeUsedCapacity: nil,
                fileIdentity: fileIdentity,
                linkCount: isDirectory ? 1 : linkCount,
                isDataless: !isDirectory && bsdFlags & BSDFileFlags.dataless != 0,
                cloneInfo: cloneInfo
            ),
            entryErrno: nil,
            isHidden: isHidden,
            deviceID: reportedDevice ?? fallbackDirectoryDevice,
            directoryMountStatus: directoryMountStatus
        )
    }

    /// Most filesystems return ATTR_CMN_DEVID for every record, eliminating
    /// the old unconditional fstat. If an exotic implementation omits it,
    /// retain correct hard-link/clone identity with one lazy directory fstat.
    private static func fallbackDevice(
        directoryFD: Int32,
        cachedDevice: inout UInt64?,
        didProbe: inout Bool
    ) -> UInt64? {
        if didProbe { return cachedDevice }
        didProbe = true
        ScanSyscallTally.recordFstatFallback()
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0 else { return nil }
        let device = UInt64(bitPattern: Int64(directoryStat.st_dev))
        cachedDevice = device
        return device
    }

    #endif

    static func isHiddenName(_ name: String) -> Bool {
        name.utf8.first == UInt8(ascii: ".")
    }

    private enum FinderFlags {
        static let hasBundle: UInt16 = 0x2000
        static let isInvisible: UInt16 = 0x4000
    }
}

/// Caches "is this filename extension a document package?" verdicts so the
/// UTType lookup runs once per distinct extension, not once per directory.
nonisolated final class PackageExtensionCatalog: @unchecked Sendable {
    static let shared = PackageExtensionCatalog()

    private let lock = NSLock()
    private var verdictByExtension: [String: Bool] = [:]

    func isPackageName(_ name: String) -> Bool {
        guard let dotIndex = name.lastIndex(of: "."),
              dotIndex != name.startIndex,
              name.index(after: dotIndex) != name.endIndex else {
            return false
        }
        let filenameExtension = String(name[name.index(after: dotIndex)...]).lowercased()

        lock.lock()
        if let cached = verdictByExtension[filenameExtension] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        #if canImport(UniformTypeIdentifiers)
        // The plain UTType(filenameExtension:) lookup resolves to *file*
        // types (e.g. "app" → com.apple.application-file); constraining the
        // lookup to directory types is what matches isPackageKey semantics.
        let directoryType = UTType(
            tag: filenameExtension,
            tagClass: .filenameExtension,
            conformingTo: .directory
        )
        let verdict = directoryType?.conforms(to: .package) ?? false
        #else
        // Only Apple platforms present directories as opaque packages.
        let verdict = false
        #endif

        lock.lock()
        verdictByExtension[filenameExtension] = verdict
        lock.unlock()
        return verdict
    }
}
