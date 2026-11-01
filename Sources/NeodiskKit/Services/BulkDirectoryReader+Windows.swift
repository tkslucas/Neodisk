// Windows has no getattrlistbulk either, but GetFileInformationByHandleEx returns whole directory-info batches
// (sizes, attributes, times, file IDs) from one directory handle: no per-entry open. Emits the same records as
// the Darwin reader. Read-only: CreateFileW(FILE_LIST_DIRECTORY), GetFileInformationByHandleEx, CloseHandle.

#if os(Windows)
import Foundation
import WinSDK

extension BulkDirectoryReader {
    /// `context` holds the directory-info batch buffer. Failures throw POSIX-domain errors with the system's
    /// message, which the scan reports as they are: there is no slower path to fall back to.
    @discardableResult
    static func readChildren(
        ofDirectory url: URL,
        using context: Context,
        category: ScanSyscallCategory = .traversal,
        cancellationCheck: CancellationCheck,
        onChild: (BulkDirectoryChild) throws -> Void
    ) throws -> Int {
        try cancellationCheck()
        if let count = try indexedChildren(ofDirectory: url, cancellationCheck: cancellationCheck, onChild: onChild) {
            return count
        }

        // Opening with FILE_FLAG_OPEN_REPARSE_POINT lists a junction or directory symlink's own (empty) contents
        // instead of its target's, the Windows O_NOFOLLOW.
        let handle = WindowsFileInfo.open(
            path: url.path,
            access: DWORD(FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES) | DWORD(SYNCHRONIZE)
        )
        guard let handle else {
            throw WindowsFileInfo.error(GetLastError(), path: url.path, url: url)
        }
        defer { CloseHandle(handle) }

        var bulkCallCount = 0
        var emittedCount = 0
        defer {
            ScanSyscallTally.recordBulkDirectory(category, bulkCalls: bulkCallCount, entries: emittedCount)
        }

        // Children of a directory share its volume; a mounted volume below it is a reparse point, never entered.
        var directoryInfo = BY_HANDLE_FILE_INFORMATION()
        let volumeSerial: UInt64? = GetFileInformationByHandle(handle, &directoryInfo)
            ? UInt64(directoryInfo.dwVolumeSerialNumber)
            : nil

        let directoryPath = url.path
        var layout = DirectoryInfoLayout.extended
        while true {
            try cancellationCheck()
            bulkCallCount += 1
            let filled = GetFileInformationByHandleEx(
                handle,
                layout.infoClass,
                context.buffer,
                DWORD(Context.bufferSize)
            )
            if !filled {
                let error = GetLastError()
                if error == DWORD(ERROR_NO_MORE_FILES) {
                    return emittedCount
                }
                // FAT, exFAT and some network redirectors lack the extended class; nothing was read yet.
                if layout.infoClass == FileIdExtdDirectoryInfo, emittedCount == 0, bulkCallCount == 1,
                   error == DWORD(ERROR_INVALID_PARAMETER) || error == DWORD(ERROR_NOT_SUPPORTED)
                    || error == DWORD(ERROR_INVALID_LEVEL) {
                    layout = .both
                    continue
                }
                throw WindowsFileInfo.error(error, path: url.path, url: url)
            }

            var entry = UnsafeRawPointer(context.buffer)
            while true {
                let nextOffset = Int(entry.loadUnaligned(as: UInt32.self))
                if let child = layout.child(at: entry, directoryPath: directoryPath, volumeSerial: volumeSerial) {
                    try onChild(child)
                    emittedCount += 1
                }
                guard nextOffset > 0 else { break }
                entry += nextOffset
            }
        }
    }

    /// The two directory-info layouts the reader asks for, decoded by field offset.
    private struct DirectoryInfoLayout {
        let infoClass: FILE_INFO_BY_HANDLE_CLASS
        let fileIDOffset: Int
        let fileIDIs128Bit: Bool
        let reparseTagOffset: Int?
        let fileNameOffset: Int

        /// FILE_ID_EXTD_DIR_INFO: a 128-bit file ID and the reparse tag.
        static let extended = DirectoryInfoLayout(
            infoClass: FileIdExtdDirectoryInfo,
            fileIDOffset: MemoryLayout<FILE_ID_EXTD_DIR_INFO>.offset(of: \FILE_ID_EXTD_DIR_INFO.FileId)!,
            fileIDIs128Bit: true,
            reparseTagOffset: MemoryLayout<FILE_ID_EXTD_DIR_INFO>.offset(of: \FILE_ID_EXTD_DIR_INFO.ReparsePointTag)!,
            fileNameOffset: MemoryLayout<FILE_ID_EXTD_DIR_INFO>.offset(of: \FILE_ID_EXTD_DIR_INFO.FileName)!
        )

        /// FILE_ID_BOTH_DIR_INFO: a 64-bit file ID; EaSize holds the reparse tag of a reparse point.
        static let both = DirectoryInfoLayout(
            infoClass: FileIdBothDirectoryInfo,
            fileIDOffset: MemoryLayout<FILE_ID_BOTH_DIR_INFO>.offset(of: \FILE_ID_BOTH_DIR_INFO.FileId)!,
            fileIDIs128Bit: false,
            reparseTagOffset: nil,
            fileNameOffset: MemoryLayout<FILE_ID_BOTH_DIR_INFO>.offset(of: \FILE_ID_BOTH_DIR_INFO.FileName)!
        )

        // Both layouts share the leading FILE_FULL_DIR_INFO fields.
        private static let lastWriteTimeOffset = 24
        private static let endOfFileOffset = 40
        private static let allocationSizeOffset = 48
        private static let attributesOffset = 56
        private static let fileNameLengthOffset = 60
        private static let eaSizeOffset = 64

        func child(at entry: UnsafeRawPointer, directoryPath: String, volumeSerial: UInt64?) -> BulkDirectoryChild? {
            let nameByteCount = Int(entry.loadUnaligned(fromByteOffset: Self.fileNameLengthOffset, as: UInt32.self))
            let nameUnits = UnsafeRawBufferPointer(start: entry + fileNameOffset, count: nameByteCount)
            if WindowsFileInfo.isDotOrDotDot(nameUnits) { return nil }
            let name = WindowsFileInfo.decodeName(nameUnits)

            let attributes = entry.loadUnaligned(fromByteOffset: Self.attributesOffset, as: UInt32.self)
            var reparseTag: UInt32 = 0
            if attributes & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
                reparseTag = entry.loadUnaligned(fromByteOffset: reparseTagOffset ?? Self.eaSizeOffset, as: UInt32.self)
            }
            let fileID: UInt64
            if fileIDIs128Bit {
                fileID = WindowsFileInfo.foldFileID(
                    low: entry.loadUnaligned(fromByteOffset: fileIDOffset, as: UInt64.self),
                    high: entry.loadUnaligned(fromByteOffset: fileIDOffset + 8, as: UInt64.self)
                )
            } else {
                fileID = entry.loadUnaligned(fromByteOffset: fileIDOffset, as: UInt64.self)
            }
            let endOfFile = entry.loadUnaligned(fromByteOffset: Self.endOfFileOffset, as: Int64.self)
            var allocationSize = entry.loadUnaligned(fromByteOffset: Self.allocationSizeOffset, as: Int64.self)
            if WindowsFileInfo.listsNoAllocation(attributes: attributes, allocationSize: allocationSize, endOfFile: endOfFile),
               let own = WindowsFileInfo.allocationSize(
                ofFileAt: ScanEngine.nodeChildPath(parentPath: directoryPath, childName: name)
               ) {
                allocationSize = own
            }
            return WindowsFileInfo.child(
                name: name,
                attributes: attributes,
                reparseTag: reparseTag,
                allocationSize: allocationSize,
                endOfFile: endOfFile,
                lastWriteTime: entry.loadUnaligned(fromByteOffset: Self.lastWriteTimeOffset, as: Int64.self),
                fileID: fileID,
                volumeSerial: volumeSerial,
                linkCount: 1
            )
        }
    }
}

/// The one conversion from Windows file information to scanner records, shared by the bulk reader, the
/// per-item loader and the NTFS index, so every path through the scanner sees the same sizes and identities.
nonisolated enum WindowsFileInfo {
    // Hard links: directory info has no link count, so every path reports 1 and a hard-linked file counts once
    // per link, as File Explorer's folder sizes do. Reading the count costs a per-file open (23-41 us a file on
    // System32, where 4,426 of 4,513 files are linked into WinSxS), several times the batched listing itself.
    // The NTFS index reads real counts from the MFT at no extra cost.

    static func child(
        name: String,
        attributes: UInt32,
        reparseTag: UInt32,
        allocationSize: Int64,
        endOfFile: Int64,
        lastWriteTime: Int64,
        fileID: UInt64,
        volumeSerial: UInt64?,
        linkCount: UInt64
    ) -> BulkDirectoryChild {
        BulkDirectoryChild(
            name: name,
            metadata: nodeMetadata(
                attributes: attributes,
                reparseTag: reparseTag,
                allocationSize: allocationSize,
                endOfFile: endOfFile,
                lastWriteTime: lastWriteTime,
                fileID: fileID,
                volumeSerial: volumeSerial,
                linkCount: linkCount
            ),
            entryErrno: nil,
            isHidden: isHidden(name: name, attributes: attributes),
            deviceID: volumeSerial,
            // Mounted volumes and junctions are reparse points, reported as links and never entered.
            directoryMountStatus: 0
        )
    }

    /// Name-surrogate reparse points (symbolic links, junctions, volume mount points) are links: leaves with no
    /// size, never followed. Other reparse points (cloud placeholders, deduplicated or compressed files) are the
    /// files and folders they look like.
    static func nodeMetadata(
        attributes: UInt32,
        reparseTag: UInt32,
        allocationSize: Int64,
        endOfFile: Int64,
        lastWriteTime: Int64,
        fileID: UInt64,
        volumeSerial: UInt64?,
        linkCount: UInt64,
        isReadable: Bool = true,
        volumeUsedCapacity: Int64? = nil
    ) -> NodeMetadata {
        let isLink = attributes & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) != 0 && isNameSurrogate(reparseTag)
        let isDirectory = !isLink && attributes & UInt32(FILE_ATTRIBUTE_DIRECTORY) != 0
        let isFile = !isLink && !isDirectory
        let logicalSize = isFile ? max(endOfFile, 0) : 0
        let allocatedSize = isFile ? max(allocationSize, 0) : 0
        let links = isFile ? max(linkCount, 1) : 1
        let capturesIdentity = !isLink && (
            isDirectory
                || links > 1
                || allocatedSize >= ScanSizeBaseline.renameTrackingMinimumFileSize
        )
        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: false,
            isSymbolicLink: isLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: date(fromFileTime: lastWriteTime),
            isReadable: isReadable,
            volumeUsedCapacity: volumeUsedCapacity,
            fileIdentity: capturesIdentity ? .fileSystem(device: volumeSerial ?? 0, inode: fileID) : nil,
            linkCount: links,
            // Cloud files whose content isn't on this machine, like dataless files on macOS.
            isDataless: isFile && attributes & cloudOnlyAttributes != 0
        )
    }

    /// Files compressed by the system (WOF, as the component store and CompactOS use) list no allocation in their
    /// directory entry: 4,327 of 4,513 files in System32. Only the file itself reports its compressed size. A file
    /// small enough to live inside its MFT record (at most 4 KB) has no clusters either, so those aren't asked.
    static func listsNoAllocation(attributes: UInt32, allocationSize: Int64, endOfFile: Int64) -> Bool {
        allocationSize == 0 && endOfFile > 4096
            && attributes & UInt32(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0
            && attributes & cloudOnlyAttributes == 0
    }

    /// The allocation the file system reports for the file itself, compressed or sparse; nil if it can't be opened.
    static func allocationSize(ofFileAt path: String) -> Int64? {
        guard let handle = open(path: path, access: DWORD(FILE_READ_ATTRIBUTES)) else { return nil }
        defer { CloseHandle(handle) }
        var standard = FILE_STANDARD_INFO()
        guard GetFileInformationByHandleEx(
            handle, FileStandardInfo, &standard, DWORD(MemoryLayout<FILE_STANDARD_INFO>.size)
        ) else { return nil }
        return max(standard.AllocationSize.QuadPart, 0)
    }

    /// FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS.
    static let cloudOnlyAttributes: UInt32 = 0x0000_1000 | 0x0004_0000 | 0x0040_0000

    /// IsReparseTagNameSurrogate (winnt.h), a macro Swift doesn't import.
    static func isNameSurrogate(_ tag: UInt32) -> Bool {
        tag & 0x2000_0000 != 0
    }

    /// Hidden as File Explorer and FileManager's `skipsHiddenFiles` see it: the attribute, not a dot name.
    static func isHidden(name: String, attributes: UInt32) -> Bool {
        attributes & UInt32(FILE_ATTRIBUTE_HIDDEN) != 0
    }

    /// NTFS file IDs are the 64-bit file reference (record number and sequence) with zero above it; only ReFS
    /// uses the upper half, which is folded in rather than dropped.
    static func foldFileID(low: UInt64, high: UInt64) -> UInt64 {
        high == 0 ? low : low ^ (high &* 0x9E37_79B9_7F4A_7C15)
    }

    /// FILETIME ticks (100 ns since 1601) to a Date; nil for 0, which file systems use for "unknown".
    static func date(fromFileTime ticks: Int64) -> Date? {
        guard ticks != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ticks - unixEpochFileTime) / 10_000_000)
    }

    /// 1970-01-01 in FILETIME ticks.
    static let unixEpochFileTime: Int64 = 116_444_736_000_000_000

    static func isDotOrDotDot(_ units: UnsafeRawBufferPointer) -> Bool {
        let dot = UInt16(UInt8(ascii: "."))
        switch units.count {
        case 2: return units.loadUnaligned(as: UInt16.self) == dot
        case 4: return units.loadUnaligned(as: UInt16.self) == dot
            && units.loadUnaligned(fromByteOffset: 2, as: UInt16.self) == dot
        default: return false
        }
    }

    /// Unpaired surrogates (legal in NTFS names) decode to U+FFFD, which the trash checks treat as undecodable.
    static func decodeName(_ units: UnsafeRawBufferPointer) -> String {
        let count = units.count / 2
        if let base = units.baseAddress, Int(bitPattern: base) % 2 == 0 {
            return String(decoding: UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt16.self), count: count), as: UTF16.self)
        }
        return String(decoding: (0..<count).map { units.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self) }, as: UTF16.self)
    }

    // MARK: - Opening

    private static var invalidHandle: HANDLE? { HANDLE(bitPattern: -1) }

    /// Opens without following a final reparse point, sharing everything so a scan never blocks another program.
    /// Nil on failure, with GetLastError set.
    static func open(path: String, access: DWORD) -> HANDLE? {
        let handle = WindowsPath.withWidePath(path) { widePath in
            CreateFileW(
                widePath,
                access,
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard let handle, handle != invalidHandle else { return nil }
        return handle
    }

    // MARK: - One item

    /// What the scanner knows about one item, read through its own handle. The scan root also gets its
    /// volume's used bytes. Failures throw POSIX-domain errors carrying the system's message.
    static func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        let path = url.path
        let handle = open(path: path, access: DWORD(FILE_READ_ATTRIBUTES))
        guard let handle else { throw error(GetLastError(), path: path, url: url) }
        defer { CloseHandle(handle) }
        guard let info = HandleInfo(handle) else { throw error(GetLastError(), path: path, url: url) }
        let volumeUsed: Int64? = includeVolumeDetails
            ? VolumeSpaceInfo.load(for: url).map { $0.usedBytes }
            : nil
        return nodeMetadata(
            attributes: info.attributes,
            reparseTag: info.reparseTag,
            allocationSize: info.allocationSize,
            endOfFile: info.endOfFile,
            lastWriteTime: info.lastWriteTime,
            fileID: info.fileID,
            volumeSerial: info.volumeSerial,
            // As the reader reports it (see above), so a relisted item matches the walk.
            linkCount: 1,
            isReadable: includeVolumeDetails ? isReadableDirectory(path, attributes: info.attributes) : true,
            volumeUsedCapacity: volumeUsed
        )
    }

    /// The scan root's readability, checked the way the reader will use it: a directory opened for listing.
    private static func isReadableDirectory(_ path: String, attributes: UInt32) -> Bool {
        guard attributes & UInt32(FILE_ATTRIBUTE_DIRECTORY) != 0 else { return true }
        guard let handle = open(path: path, access: DWORD(FILE_LIST_DIRECTORY)) else { return false }
        CloseHandle(handle)
        return true
    }

    /// The fields the scanner reads from an open handle.
    struct HandleInfo {
        let attributes: UInt32
        let reparseTag: UInt32
        let allocationSize: Int64
        let endOfFile: Int64
        let lastWriteTime: Int64
        let fileID: UInt64
        let volumeSerial: UInt64
        let linkCount: UInt64

        init?(_ handle: HANDLE) {
            var byHandle = BY_HANDLE_FILE_INFORMATION()
            var basic = FILE_BASIC_INFO()
            var standard = FILE_STANDARD_INFO()
            guard GetFileInformationByHandle(handle, &byHandle),
                  GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, DWORD(MemoryLayout<FILE_BASIC_INFO>.size)),
                  GetFileInformationByHandleEx(
                    handle, FileStandardInfo, &standard, DWORD(MemoryLayout<FILE_STANDARD_INFO>.size)
                  ) else {
                return nil
            }
            attributes = basic.FileAttributes
            var tag: UInt32 = 0
            if attributes & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
                var tagInfo = FILE_ATTRIBUTE_TAG_INFO()
                if GetFileInformationByHandleEx(
                    handle, FileAttributeTagInfo, &tagInfo, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
                ) {
                    tag = tagInfo.ReparseTag
                }
            }
            reparseTag = tag
            allocationSize = standard.AllocationSize.QuadPart
            endOfFile = standard.EndOfFile.QuadPart
            lastWriteTime = basic.LastWriteTime.QuadPart
            linkCount = UInt64(max(standard.NumberOfLinks, 1))
            volumeSerial = UInt64(byHandle.dwVolumeSerialNumber)
            // The same 128-bit ID the directory info reports, folded the same way; FAT has only the 64-bit index.
            var idInfo = FILE_ID_INFO()
            if GetFileInformationByHandleEx(handle, FileIdInfo, &idInfo, DWORD(MemoryLayout<FILE_ID_INFO>.size)) {
                fileID = withUnsafeBytes(of: idInfo.FileId) { raw in
                    WindowsFileInfo.foldFileID(
                        low: raw.loadUnaligned(as: UInt64.self),
                        high: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                    )
                }
            } else {
                fileID = UInt64(byHandle.nFileIndexHigh) << 32 | UInt64(byHandle.nFileIndexLow)
            }
        }
    }

    // MARK: - Errors

    /// Win32 errors as the errno the other platforms' scanner code already classifies.
    static func posixCode(_ error: DWORD) -> Int32 {
        switch Int32(bitPattern: error) {
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME, ERROR_BAD_NETPATH, ERROR_BAD_NET_NAME,
             ERROR_INVALID_DRIVE, ERROR_NOT_READY:
            return ENOENT
        case ERROR_ACCESS_DENIED, ERROR_PRIVILEGE_NOT_HELD, ERROR_CANT_ACCESS_FILE, ERROR_SHARING_VIOLATION,
             ERROR_LOCK_VIOLATION:
            return EACCES
        case ERROR_DIRECTORY:
            return ENOTDIR
        case ERROR_FILENAME_EXCED_RANGE:
            return ENAMETOOLONG
        case ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY:
            return ENOMEM
        default:
            return EIO
        }
    }

    /// The system's own wording for a Win32 error, without the trailing line break.
    static func message(_ error: DWORD) -> String {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let length = FormatMessageW(
            DWORD(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS),
            nil,
            error,
            0,
            &buffer,
            DWORD(buffer.count),
            nil
        )
        guard length > 0 else { return "Windows error \(error)" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func error(_ error: DWORD, path: String, url: URL? = nil) -> NSError {
        var userInfo: [String: Any] = [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: message(error),
        ]
        if let url { userInfo[NSURLErrorKey] = url }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(posixCode(error)), userInfo: userInfo)
    }
}

/// Scanner paths are `URL.path` spellings (`C:/Users/x`, `//server/share/x`); Win32 calls get them as wide
/// strings with backslashes, and past MAX_PATH with the `\\?\` prefix that lifts the limit.
nonisolated enum WindowsPath {
    static func withWidePath<Result>(_ path: String, _ body: (UnsafePointer<WCHAR>) throws -> Result) rethrows -> Result {
        try native(path).withCString(encodedAs: UTF16.self, body)
    }

    static func native(_ path: String) -> String {
        var native = path.replacingOccurrences(of: "/", with: "\\")
        // CreateDirectoryW's limit (MAX_PATH minus a short name) is the tightest of the APIs used here.
        guard native.utf16.count >= 248, !native.hasPrefix("\\\\?\\") else { return native }
        if native.hasPrefix("\\\\") {
            native = "\\\\?\\UNC\\" + native.dropFirst(2)
        } else if isDriveAbsolute(native) {
            native = "\\\\?\\" + native
        }
        return native
    }

    static func string(fromNullTerminated buffer: [WCHAR]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    static func createHardLink(at path: String, to existingPath: String) -> Bool {
        withWidePath(path) { linkPath in
            withWidePath(existingPath) { CreateHardLinkW(linkPath, $0, nil) }
        }
    }

    /// `.` and `..` resolved without touching the disk, in `URL.path` form: forward slashes, a drive root keeps
    /// its slash (`C:/`), nothing climbs above a drive or share. Foundation's `standardizedFileURL` turns `C:/`
    /// into a path under the current directory.
    static func lexicallyStandardized(_ path: String) -> String {
        let isUNC = path.hasPrefix("//") || path.hasPrefix("\\\\")
        var components: [Substring] = []
        for component in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            switch component {
            case ".": continue
            case "..": if components.count > (isUNC ? 2 : 1) { components.removeLast() }
            default: components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if isUNC { return "//" + joined }
        if components.count == 1, components[0].hasSuffix(":") { return joined + "/" }
        return path.hasPrefix("/") && !isDriveAbsolute(String(path.dropFirst())) ? "/" + joined : joined
    }

    static func isDriveRoot(_ path: String) -> Bool {
        let standardized = lexicallyStandardized(path)
        return standardized.utf16.count == 3 && isDriveAbsolute(standardized)
    }

    /// A scan root as the scanner spells it: standardized, and a symlinked root resolved as on the other
    /// platforms. Drive roots and shares are taken as given; Foundation's resolution mangles them.
    static func normalizedRootURL(_ url: URL) -> URL {
        var path = lexicallyStandardized(url.path)
        if !isDriveRoot(path), !path.hasPrefix("//") {
            path = lexicallyStandardized(URL(filePath: path).resolvingSymlinksInPath().path)
        }
        return URL(filePath: path, directoryHint: url.hasDirectoryPath ? .isDirectory : .inferFromPath)
    }

    /// `C:\…` or `C:/…`.
    static func isDriveAbsolute(_ path: String) -> Bool {
        let units = Array(path.utf16.prefix(3))
        guard units.count == 3, units[1] == UInt16(UInt8(ascii: ":")) else { return false }
        let letter = units[0] | 0x20
        return letter >= UInt16(UInt8(ascii: "a")) && letter <= UInt16(UInt8(ascii: "z"))
            && (units[2] == UInt16(UInt8(ascii: "\\")) || units[2] == UInt16(UInt8(ascii: "/")))
    }

    /// The path with symbolic links, junctions and mount points resolved, as the system spells it
    /// (GetFinalPathNameByHandleW), in `URL.path` form. Nil when it can't be opened.
    static func resolved(_ path: String) -> String? {
        let handle = withWidePath(path) { widePath in
            CreateFileW(
                widePath,
                DWORD(FILE_READ_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                nil
            )
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { return nil }
        defer { CloseHandle(handle) }
        var buffer = [WCHAR](repeating: 0, count: 1024)
        var length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
        if length >= DWORD(buffer.count) {
            buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
            length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
        }
        guard length > 0, length < DWORD(buffer.count) else { return nil }
        var resolved = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        if resolved.hasPrefix("\\\\?\\UNC\\") {
            resolved = "\\\\" + resolved.dropFirst(8)
        } else if resolved.hasPrefix("\\\\?\\") {
            resolved = String(resolved.dropFirst(4))
        }
        return URL(fileURLWithPath: resolved).path
    }
}
#endif
