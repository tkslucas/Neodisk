//
//  BulkDirectoryReader.swift
//  Neodisk
//
//  One getattrlistbulk(2) loop returns every child of a directory together
//  with the metadata the scanner needs (type, sizes, mod date, link count,
//  inode, flags, readability) — replacing the FileManager enumerator plus a
//  per-child resourceValues() call, i.e. one syscall per ~few-hundred entries
//  instead of several syscalls per entry. Read-only by construction: the only
//  operations are open(O_RDONLY), fstat, getattrlistbulk, and close.
//

import Darwin
import Foundation
import UniformTypeIdentifiers

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
}

nonisolated enum BulkDirectoryReadError: Error {
    /// open(2) on the directory failed (errno attached).
    case openFailed(Int32)
    /// getattrlistbulk(2) failed (errno attached); caller should fall back.
    case bulkListFailed(Int32)
}

nonisolated enum BulkDirectoryReader {
    /// Reads all children of `url` in getattrlistbulk batches.
    /// Throws on any failure — callers fall back to the FileManager path so
    /// exotic volumes and permission errors keep their existing semantics.
    static func children(
        ofDirectory url: URL,
        cancellationCheck: CancellationCheck
    ) throws -> [BulkDirectoryChild] {
        try cancellationCheck()

        // Never trigger downloads of dataless (cloud-evicted) files while
        // enumerating. Thread-scoped and cheap; cooperative-pool threads are
        // reused, so keep re-asserting rather than assuming a prior call.
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )

        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw BulkDirectoryReadError.openFailed(errno)
        }
        defer { close(fd) }

        // Hard links are deduplicated by (device, inode); all children share
        // the directory's device except mount points, which cannot be
        // hard-linked regular files anyway.
        var directoryStat = stat()
        let device: UInt64 = fstat(fd, &directoryStat) == 0
            ? UInt64(bitPattern: Int64(directoryStat.st_dev))
            : 0

        var commonAttributes: UInt32 = ATTR_CMN_RETURNED_ATTRS
        commonAttributes |= RequestedAttributes.error
        commonAttributes |= RequestedAttributes.name
        commonAttributes |= RequestedAttributes.objectType
        commonAttributes |= RequestedAttributes.modificationTime
        commonAttributes |= RequestedAttributes.finderInfo
        commonAttributes |= RequestedAttributes.flags
        commonAttributes |= RequestedAttributes.userAccess
        commonAttributes |= RequestedAttributes.fileID
        var fileAttributes: UInt32 = RequestedAttributes.fileLinkCount
        fileAttributes |= RequestedAttributes.fileAllocatedSize
        fileAttributes |= RequestedAttributes.fileDataLength

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = commonAttributes
        request.fileattr = fileAttributes
        // With FSOPT_ATTR_CMN_EXTENDED the forkattr field carries the
        // common-extended attributes (we request no real fork attributes):
        // clone-family identity, so shared-block files can be deduplicated.
        // Filesystems without clone tracking simply omit them per entry.
        request.forkattr = RequestedAttributes.cloneID | RequestedAttributes.cloneRefCount

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var children: [BulkDirectoryChild] = []
        while true {
            try cancellationCheck()
            let batchCount = getattrlistbulk(fd, &request, buffer, bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if batchCount < 0 {
                throw BulkDirectoryReadError.bulkListFailed(errno)
            }
            if batchCount == 0 {
                return children
            }

            var entry = buffer
            for _ in 0..<batchCount {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                parseEntry(at: entry, device: device, into: &children)
                entry += entryLength
            }
        }
    }

    /// UInt32 views of the sys/attr.h request bits (they import into Swift
    /// with mixed signedness; attrgroup_t is UInt32).
    private enum RequestedAttributes {
        static let error = UInt32(bitPattern: ATTR_CMN_ERROR)
        static let name = UInt32(bitPattern: ATTR_CMN_NAME)
        static let objectType = UInt32(bitPattern: ATTR_CMN_OBJTYPE)
        static let modificationTime = UInt32(bitPattern: ATTR_CMN_MODTIME)
        static let finderInfo = UInt32(bitPattern: ATTR_CMN_FNDRINFO)
        static let flags = UInt32(bitPattern: ATTR_CMN_FLAGS)
        static let userAccess = UInt32(bitPattern: ATTR_CMN_USERACCESS)
        static let fileID = UInt32(bitPattern: ATTR_CMN_FILEID)
        static let fileLinkCount = UInt32(bitPattern: ATTR_FILE_LINKCOUNT)
        static let fileAllocatedSize = UInt32(bitPattern: ATTR_FILE_ALLOCSIZE)
        static let fileDataLength = UInt32(bitPattern: ATTR_FILE_DATALENGTH)
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
        device: UInt64,
        into children: inout [BulkDirectoryChild]
    ) {
        var field = entryStart + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
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
        if common & RequestedAttributes.name != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let nameStart = field + Int(reference.attr_dataoffset)
            if reference.attr_length > 0 {
                name = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
            }
            field += MemoryLayout<attrreference_t>.size
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

        guard let name else { return }

        if let entryErrno {
            children.append(BulkDirectoryChild(
                name: name,
                metadata: nil,
                entryErrno: entryErrno,
                isHidden: isHiddenName(name)
            ))
            return
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
        let cloneInfo: CloneInfo? = !isDirectory && !isSymbolicLink
            && cloneRefCount > 1
            ? cloneID.map { CloneInfo(device: device, cloneID: $0, refCount: cloneRefCount) }
            : nil

        children.append(BulkDirectoryChild(
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
            isHidden: isHidden
        ))
    }

    private static func isHiddenName(_ name: String) -> Bool {
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

        // The plain UTType(filenameExtension:) lookup resolves to *file*
        // types (e.g. "app" → com.apple.application-file); constraining the
        // lookup to directory types is what matches isPackageKey semantics.
        let directoryType = UTType(
            tag: filenameExtension,
            tagClass: .filenameExtension,
            conformingTo: .directory
        )
        let verdict = directoryType?.conforms(to: .package) ?? false

        lock.lock()
        verdictByExtension[filenameExtension] = verdict
        lock.unlock()
        return verdict
    }
}
