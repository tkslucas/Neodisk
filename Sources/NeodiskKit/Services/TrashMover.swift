import Foundation
#if os(Windows)
import WinSDK
#endif

/// Why one item didn't reach the Trash. Every case leaves the item where it was.
public enum TrashFailure: Error, Sendable, Equatable {
    case refused(TrashRefusal)
    /// Nothing is at the path anymore.
    case missing
    /// Something else is at the path now (replaced, or a different kind of item).
    case changedSinceScan
    /// The item is locked (Finder's Get Info), which the Trash won't take.
    case locked
    /// The system declined the move: no Trash on that volume, no permission, a locked file, SIP.
    case systemError(String)
}

/// What lstat says is at a path now, read with the same device conversion the scanner uses.
public enum CurrentFileState: Sendable, Equatable {
    case found(CurrentFile)
    case missing
    case unreadable(String)

    public static func read(atPath path: String) -> CurrentFileState {
        #if os(Windows)
        return readWindows(atPath: path)
        #else
        var status = stat()
        guard lstat(path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .unreadable(String(cString: strerror(code)))
        }
        let kind: CurrentFile.Kind = switch status.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .file
        }
        #if canImport(Darwin)
        // bitPattern, as in the scanner: dev_t is signed and some volumes report negative device numbers,
        // which `UInt64(_:)` would trap on, and any other conversion would never match.
        let device = UInt64(bitPattern: Int64(status.st_dev))
        let modified = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
        #else
        let device = UInt64(status.st_dev)
        let modified = Double(status.st_mtim.tv_sec) + Double(status.st_mtim.tv_nsec) / 1e9
        #endif
        return .found(CurrentFile(
            identity: .fileSystem(device: device, inode: UInt64(status.st_ino)),
            kind: kind,
            size: Int64(status.st_size),
            modifiedSince1970: modified
        ))
        #endif
    }

    #if os(Windows)
    /// The item itself, never a link's target, with the identity the scanner recorded (volume serial, file ID).
    private static func readWindows(atPath path: String) -> CurrentFileState {
        guard let handle = WindowsFileInfo.open(path: path, access: DWORD(FILE_READ_ATTRIBUTES)) else {
            let error = GetLastError()
            if WindowsFileInfo.posixCode(error) == ENOENT { return .missing }
            return .unreadable(WindowsFileInfo.message(error))
        }
        defer { CloseHandle(handle) }
        guard let info = WindowsFileInfo.HandleInfo(handle) else {
            return .unreadable(WindowsFileInfo.message(GetLastError()))
        }
        let metadata = WindowsFileInfo.nodeMetadata(
            attributes: info.attributes,
            reparseTag: info.reparseTag,
            allocationSize: info.allocationSize,
            endOfFile: info.endOfFile,
            lastWriteTime: info.lastWriteTime,
            fileID: info.fileID,
            volumeSerial: info.volumeSerial,
            linkCount: info.linkCount
        )
        let kind: CurrentFile.Kind = metadata.isSymbolicLink
            ? .symbolicLink
            : (metadata.isDirectory ? .directory : .file)
        return .found(CurrentFile(
            identity: .fileSystem(device: info.volumeSerial, inode: info.fileID),
            kind: kind,
            size: info.endOfFile,
            modifiedSince1970: Double(info.lastWriteTime - WindowsFileInfo.unixEpochFileTime) / 10_000_000
        ))
    }
    #endif
}

public struct CurrentFile: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file, directory, symbolicLink
    }

    public let identity: FileIdentity
    public let kind: Kind
    public let size: Int64
    public let modifiedSince1970: Double
}

/// Moves scanned items to the Trash, one at a time, each checked right before its move: still allowed by the
/// policy, still the item the scan saw. Never deletes: when the system can't trash an item, it stays put.
public struct TrashMover: Sendable {
    public typealias TrashItem = @Sendable (URL) throws -> URL?

    private let policy: TrashSafetyPolicy
    private let trashItem: TrashItem

    public init(policy: TrashSafetyPolicy, trashItem: @escaping TrashItem = TrashMover.systemTrash) {
        self.policy = policy
        self.trashItem = trashItem
    }

    /// FileManager's Trash on Apple platforms (Finder can put items back). Linux apps pass GIO's.
    public static let systemTrash: TrashItem = { url in
        #if canImport(Darwin)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// Moves one item. Blocking: call off the main thread.
    public func move(_ node: FileNodeRecord, scanRootID: String) -> Result<URL?, TrashFailure> {
        if let refusal = policy.refusal(for: node, scanRootID: scanRootID) {
            return .failure(.refused(refusal))
        }
        if let failure = Self.verify(node) {
            return .failure(failure)
        }
        // The check and the move are as close together as a path-based API allows.
        do {
            return .success(try trashItem(node.url))
        } catch {
            return .failure(Self.isLocked(node.path) ? .locked : .systemError(error.localizedDescription))
        }
    }

    /// The user or system immutable flag, which the system reports only as "no permission".
    static func isLocked(_ path: String) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
        #else
        return false
        #endif
    }

    /// Nil when the path still holds the scanned item: same device and inode when known, and for files also the
    /// same size and date (inodes get reused, and an edited file isn't what the user saw).
    public static func verify(_ node: FileNodeRecord) -> TrashFailure? {
        let current: CurrentFile
        switch CurrentFileState.read(atPath: node.path) {
        case .missing:
            return .missing
        case .unreadable(let reason):
            return .systemError(reason)
        case .found(let file):
            current = file
        }
        let expectedKind: CurrentFile.Kind = node.isSymbolicLink
            ? .symbolicLink
            : (node.isDirectory ? .directory : .file)
        guard current.kind == expectedKind else { return .changedSinceScan }

        switch node.fileIdentity {
        case .fileSystem(let device, let inode):
            guard current.identity == .fileSystem(device: device, inode: inode) else { return .changedSinceScan }
            return node.isDirectory ? nil : unchangedFile(node, current)
        case .resourceIdentifier(let scanned):
            #if canImport(Darwin)
            let values = try? node.url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            guard let identifier = values?.fileResourceIdentifier as? Data, identifier == scanned else {
                return .changedSinceScan
            }
            return node.isDirectory ? nil : unchangedFile(node, current)
            #else
            _ = scanned
            return .changedSinceScan
            #endif
        case nil:
            // Folders always carry an identity; one without can't be confirmed.
            guard !node.isDirectory else { return .changedSinceScan }
            return unchangedFile(node, current)
        }
    }

    /// Same size (files; a symlink's is its target path) and modification date, within a second.
    private static func unchangedFile(_ node: FileNodeRecord, _ current: CurrentFile) -> TrashFailure? {
        if current.kind == .file, current.size != node.logicalSize {
            return .changedSinceScan
        }
        if let scanned = node.lastModified?.timeIntervalSince1970,
           abs(scanned - current.modifiedSince1970) > 1 {
            return .changedSinceScan
        }
        return nil
    }
}
