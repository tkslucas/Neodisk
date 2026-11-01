// The Recycle Bin on Windows, through the shell's file operation engine (IFileOperation), so File Explorer can
// restore what Neodisk moved.
//
// The engine's recycle delete (FOFX_RECYCLEONDELETE with FOF_NOCONFIRMATION) silently deletes permanently
// whatever it decides not to recycle. Its progress sink sees that decision only for some items: PreDeleteItem
// lacks TSF_DELETE_RECYCLE_IF_POSSIBLE on a drive without a Recycle Bin, on a volume set to remove files
// immediately and for a single path past MAX_PATH, and the sink aborts those. It still reports a recycle for an
// item larger than the bin's maximum size and for a folder holding a path past MAX_PATH, then deletes with no
// callback in between, so the checks before the operation refuse those. FOF_WANTNUKEWARNING turns anything the
// checks still missed into the system's question instead of a silent delete.

#if os(Windows)
import Foundation
import WinSDK

/// Why the Recycle Bin can't take an item. The item stays where it was.
nonisolated enum RecycleBinRefusal: Error, Equatable, LocalizedError {
    /// A removable, network or optical drive, or a volume whose Recycle Bin doesn't answer.
    case noRecycleBin
    /// The volume's Recycle Bin is set to remove files immediately, or a policy turns it off.
    case removesImmediately
    /// Larger than the most the volume's Recycle Bin takes in one item.
    case tooLarge
    /// The item, or something inside it, has a path too long for the Recycle Bin.
    case pathTooLong
    /// The shell declined to recycle it.
    case declined

    var errorDescription: String? {
        switch self {
        case .noRecycleBin: "This drive has no Recycle Bin, so Neodisk can't move it there."
        case .removesImmediately: "This drive's Recycle Bin is set to remove files immediately, so Neodisk won't move it."
        case .tooLarge: "It's larger than this drive's Recycle Bin can hold. Raise the Recycle Bin's maximum size to move it."
        case .pathTooLong: "Its path, or the path of something inside it, is too long for the Recycle Bin."
        case .declined: "Windows wouldn't put it in the Recycle Bin, so Neodisk left it in place."
        }
    }
}

/// A shell operation that failed, in the system's words.
nonisolated struct RecycleBinOperationError: Error, LocalizedError {
    let result: HRESULT
    var errorDescription: String? {
        // HRESULT_FROM_WIN32 codes carry a Win32 error the system can word; the shell's own codes don't.
        let code = UInt32(bitPattern: result)
        if code & 0xFFFF_0000 == 0x8007_0000 { return WindowsFileInfo.message(DWORD(code & 0xFFFF)) }
        return "Windows couldn't move it to the Recycle Bin (error 0x\(String(code, radix: 16)))."
    }
}

/// The volume's Recycle Bin settings, as the shell reads them.
nonisolated struct RecycleBinSettings: Sendable, Equatable {
    var removesImmediately: Bool
    /// The largest single item the bin takes, in bytes of logical size, inclusive.
    var maxItemBytes: Int64
}

nonisolated struct WindowsRecycleBin: Sendable {
    /// Paths this long or longer, in UTF-16 units, are refused: a folder holding one is deleted rather than
    /// recycled (seen at 248 and up; the exact limit wasn't pinned down, so this errs on the safe side).
    static let pathLengthLimit = 248

    /// Nil when the volume's settings can't be read: the move is refused. Tests inject their own.
    var settings: @Sendable (_ volumeRoot: String) -> RecycleBinSettings?

    static let live = WindowsRecycleBin(settings: readSettings(volumeRoot:))

    /// Checks the item against the volume's Recycle Bin, then moves it there. Returns where it landed.
    func recycle(_ url: URL) throws -> URL? {
        let path = WindowsPath.lexicallyStandardized(url.path).replacingOccurrences(of: "/", with: "\\")
        try check(path)
        return try ShellRecycleOperation.run(path)
    }

    func check(_ path: String) throws {
        guard let root = WindowsVolume.root(for: path),
              WindowsVolume.driveType(root: root) == UINT(DRIVE_FIXED) else {
            throw RecycleBinRefusal.noRecycleBin
        }
        var info = SHQUERYRBINFO()
        info.cbSize = DWORD(MemoryLayout<SHQUERYRBINFO>.size)
        // Also creates the volume's settings with their default maximum size, on a volume never used before.
        let answered = root.withCString(encodedAs: UTF16.self) { SHQueryRecycleBinW($0, &info) }
        guard answered == S_OK else { throw RecycleBinRefusal.noRecycleBin }
        guard let settings = settings(root) else { throw RecycleBinRefusal.noRecycleBin }
        if settings.removesImmediately { throw RecycleBinRefusal.removesImmediately }
        try Self.measure(path, limit: settings.maxItemBytes)
    }

    /// Walks the item without following links: its logical size (a folder's total) must stay within `limit`,
    /// and every path inside must be shorter than `pathLengthLimit`. Stops at the first problem.
    static func measure(_ path: String, limit: Int64) throws {
        var total: Int64 = 0
        var pending = [path]
        while let current = pending.popLast() {
            guard current.utf16.count < pathLengthLimit else { throw RecycleBinRefusal.pathTooLong }
            var data = WIN32_FIND_DATAW()
            let found = WindowsPath.withWidePath(current) {
                FindFirstFileExW($0, FindExInfoBasic, &data, FindExSearchNameMatch, nil, 0)
            }
            guard let found, found != HANDLE(bitPattern: -1) else { throw RecycleBinRefusal.declined }
            FindClose(found)
            let attributes = data.dwFileAttributes
            guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                  attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
                total += Int64(data.nFileSizeHigh) << 32 | Int64(data.nFileSizeLow)
                if total > limit { throw RecycleBinRefusal.tooLarge }
                continue
            }
            let children = WindowsPath.withWidePath(current + "\\*") {
                FindFirstFileExW($0, FindExInfoBasic, &data, FindExSearchNameMatch, nil, DWORD(FIND_FIRST_EX_LARGE_FETCH))
            }
            guard let children, children != HANDLE(bitPattern: -1) else { throw RecycleBinRefusal.declined }
            defer { FindClose(children) }
            repeat {
                let name = withUnsafeBytes(of: data.cFileName) {
                    String(decoding: $0.bindMemory(to: WCHAR.self).prefix { $0 != 0 }, as: UTF16.self)
                }
                if name != "." && name != ".." { pending.append(current + "\\" + name) }
            } while FindNextFileW(children, &data)
        }
    }

    /// The shell's settings for the volume: its own key under the user's BitBucket settings, and the policies
    /// an administrator can set over it.
    static func readSettings(volumeRoot: String) -> RecycleBinSettings? {
        var volumeName = [WCHAR](repeating: 0, count: 64)
        let named = volumeRoot.withCString(encodedAs: UTF16.self) {
            GetVolumeNameForVolumeMountPointW($0, &volumeName, DWORD(volumeName.count))
        }
        guard named else { return nil }
        // `\\?\Volume{GUID}\` -> `{GUID}`
        let name = WindowsPath.string(fromNullTerminated: volumeName)
        guard let open = name.firstIndex(of: "{"), let close = name.firstIndex(of: "}") else { return nil }
        let key = #"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\"# + name[open...close]
        guard let megabytes = registryDWORD(HKEY_CURRENT_USER, key, "MaxCapacity") else { return nil }
        var maxItemBytes = Int64(megabytes) * 1_048_576
        // A policy's percentage of the volume, when set, may be what the shell goes by: take the smaller.
        if let percent = policyDWORD("RecycleBinSize") {
            var total = ULARGE_INTEGER()
            let read = volumeRoot.withCString(encodedAs: UTF16.self) { GetDiskFreeSpaceExW($0, nil, &total, nil) }
            guard read else { return nil }
            maxItemBytes = min(maxItemBytes, Int64(total.QuadPart / 100) * Int64(min(percent, 100)))
        }
        let nukeOnDelete = registryDWORD(HKEY_CURRENT_USER, key, "NukeOnDelete").map { $0 != 0 } ?? false
        let noRecycleFiles = policyDWORD("NoRecycleFiles").map { $0 != 0 } ?? false
        return RecycleBinSettings(removesImmediately: nukeOnDelete || noRecycleFiles, maxItemBytes: maxItemBytes)
    }

    private static func policyDWORD(_ name: String) -> DWORD? {
        let key = #"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"#
        return registryDWORD(HKEY_CURRENT_USER, key, name) ?? registryDWORD(HKEY_LOCAL_MACHINE, key, name)
    }

    private static func registryDWORD(_ hive: HKEY, _ key: String, _ name: String) -> DWORD? {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = key.withCString(encodedAs: UTF16.self) { wideKey in
            name.withCString(encodedAs: UTF16.self) { wideName in
                RegGetValueW(hive, wideKey, wideName, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS ? value : nil
    }
}

/// One IFileOperation delete with FOFX_RECYCLEONDELETE, on a thread of its own in a single-threaded apartment
/// as the shell wants, with a progress sink that aborts an item the shell says it won't recycle.
nonisolated enum ShellRecycleOperation {
    private static let clsidFileOperation = GUID(
        Data1: 0x3AD0_5575, Data2: 0x8857, Data3: 0x4850, Data4: (0x92, 0x77, 0x11, 0xB8, 0x5B, 0xDB, 0x8E, 0x09)
    )
    private static let iidFileOperation = GUID(
        Data1: 0x947A_AB5F, Data2: 0x0A5C, Data3: 0x4C13, Data4: (0xB4, 0xD6, 0x4B, 0xF7, 0x83, 0x6F, 0xC9, 0xF8)
    )
    fileprivate static let iidProgressSink = GUID(
        Data1: 0x04B0_F1A7, Data2: 0x9490, Data3: 0x44BC, Data4: (0x96, 0xE1, 0x42, 0x96, 0xA3, 0x12, 0x52, 0xE2)
    )
    fileprivate static let iidUnknown = GUID(
        Data1: 0, Data2: 0, Data3: 0, Data4: (0xC0, 0, 0, 0, 0, 0, 0, 0x46)
    )
    private static let iidShellItem = GUID(
        Data1: 0x4382_6D1E, Data2: 0xE718, Data3: 0x42EE, Data4: (0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE)
    )

    // FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_WANTNUKEWARNING | FOFX_RECYCLEONDELETE
    private static let flags: DWORD = 0x4 | 0x10 | 0x400 | 0x4000 | 0x8_0000
    /// TSF_DELETE_RECYCLE_IF_POSSIBLE, in PreDeleteItem's flags when the shell means to recycle.
    fileprivate static let recycleIfPossible: DWORD = 0x80
    fileprivate static let abort = HRESULT(bitPattern: 0x8000_4004)

    static func run(_ path: String) throws -> URL? {
        switch onApartmentThread({ perform(path) }) {
        case .recycled(let location): return URL(fileURLWithPath: location)
        case .failed(let error): throw error
        }
    }

    enum Outcome: Sendable {
        case recycled(String)
        case failed(any Error & Sendable)
    }

    private static func perform(_ path: String) -> Outcome {
        // Created first so it outlives the operation that points at it.
        let sink = ProgressSink()
        defer { sink.release() }
        var clsid = clsidFileOperation
        var iid = iidFileOperation
        var raw: UnsafeMutableRawPointer?
        var result = CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, &raw)
        guard result == S_OK, let raw else { return .failed(RecycleBinOperationError(result: result)) }
        let operation = raw.assumingMemoryBound(to: IFileOperation.self)
        let calls = operation.pointee.lpVtbl.pointee
        defer { _ = calls.Release(operation) }

        result = calls.SetOperationFlags(operation, flags)
        guard result == S_OK else { return .failed(RecycleBinOperationError(result: result)) }

        var cookie: DWORD = 0
        result = calls.Advise(operation, sink.pointer, &cookie)
        guard result == S_OK else { return .failed(RecycleBinOperationError(result: result)) }
        defer { _ = calls.Unadvise(operation, cookie) }

        var itemIID = iidShellItem
        var itemRaw: UnsafeMutableRawPointer?
        result = WindowsPath.withWidePath(path) { SHCreateItemFromParsingName($0, nil, &itemIID, &itemRaw) }
        guard result == S_OK, let itemRaw else { return .failed(RecycleBinOperationError(result: result)) }
        let item = itemRaw.assumingMemoryBound(to: IShellItem.self)
        defer { _ = item.pointee.lpVtbl.pointee.Release(item) }

        result = calls.DeleteItem(operation, item, nil)
        guard result == S_OK else { return .failed(RecycleBinOperationError(result: result)) }
        result = calls.PerformOperations(operation)

        let state = sink.state
        if state.declined { return .failed(RecycleBinRefusal.declined) }
        guard result >= 0, let deleteResult = state.deleteResult else {
            return .failed(RecycleBinOperationError(result: result))
        }
        guard deleteResult >= 0 else { return .failed(RecycleBinOperationError(result: deleteResult)) }
        var aborted: WindowsBool = false
        _ = calls.GetAnyOperationsAborted(operation, &aborted)
        if aborted.boolValue { return .failed(RecycleBinRefusal.declined) }
        // The checks rule this out; if the shell removed the item without a new one in the bin, say so.
        guard let location = state.newLocation else {
            return .failed(RecycleBinOperationError(result: HRESULT(bitPattern: 0x8000_4005)))
        }
        return .recycled(location)
    }

    /// Runs `body` on a new thread that joins a single-threaded apartment, and waits for it.
    private static func onApartmentThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let initialized = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
            box.value = body()
            if initialized >= 0 { CoUninitialize() }
            done.signal()
        }
        thread.start()
        done.wait()
        return box.value!
    }
}

/// Written by the apartment thread before the semaphore signals, read after the wait.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

/// What the sink saw during one operation (one item).
private final class SinkState {
    var declined = false
    var deleteResult: HRESULT?
    var newLocation: String?
}

/// IFileOperationProgressSink, laid out by hand: the interface's vtable pointer, then this sink's state. The
/// operation holds it only between Advise and Unadvise, inside `perform`, so reference counting is a no-op.
private final class ProgressSink {
    let pointer: UnsafeMutablePointer<IFileOperationProgressSink>
    let state = SinkState()
    private let memory: UnsafeMutableRawPointer
    private let table: UnsafeMutablePointer<IFileOperationProgressSinkVtbl>

    init() {
        table = .allocate(capacity: 1)
        table.initialize(to: Self.vtable())
        let slot = MemoryLayout<UnsafeRawPointer>.stride
        memory = .allocate(byteCount: 2 * slot, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        memory.storeBytes(of: UnsafeMutableRawPointer(table), as: UnsafeMutableRawPointer.self)
        memory.storeBytes(of: Unmanaged.passUnretained(state).toOpaque(), toByteOffset: slot, as: UnsafeMutableRawPointer.self)
        pointer = memory.assumingMemoryBound(to: IFileOperationProgressSink.self)
    }

    func release() {
        memory.deallocate()
        table.deinitialize(count: 1)
        table.deallocate()
    }

    private static func sinkState(_ this: UnsafeMutablePointer<IFileOperationProgressSink>?) -> SinkState? {
        guard let this else { return nil }
        let context = UnsafeMutableRawPointer(this)
            .load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.stride, as: UnsafeMutableRawPointer.self)
        return Unmanaged<SinkState>.fromOpaque(context).takeUnretainedValue()
    }

    private static func filesystemPath(_ item: UnsafeMutablePointer<IShellItem>?) -> String? {
        guard let item else { return nil }
        var name: PWSTR?
        guard item.pointee.lpVtbl.pointee.GetDisplayName(item, SIGDN_FILESYSPATH, &name) == S_OK, let name else {
            return nil
        }
        defer { CoTaskMemFree(name) }
        return String(decodingCString: name, as: UTF16.self)
    }

    private static func vtable() -> IFileOperationProgressSinkVtbl {
        IFileOperationProgressSinkVtbl(
            QueryInterface: { this, riid, out in
                guard let riid, let out else { return HRESULT(bitPattern: 0x8000_4003) }
                var unknown = ShellRecycleOperation.iidUnknown
                var sink = ShellRecycleOperation.iidProgressSink
                let size = MemoryLayout<GUID>.size
                if memcmp(riid, &unknown, size) == 0 || memcmp(riid, &sink, size) == 0 {
                    out.pointee = UnsafeMutableRawPointer(this)
                    return S_OK
                }
                out.pointee = nil
                return HRESULT(bitPattern: 0x8000_4002)
            },
            AddRef: { _ in 1 },
            Release: { _ in 1 },
            StartOperations: { _ in S_OK },
            FinishOperations: { _, _ in S_OK },
            PreRenameItem: { _, _, _, _ in S_OK },
            PostRenameItem: { _, _, _, _, _, _ in S_OK },
            PreMoveItem: { _, _, _, _, _ in S_OK },
            PostMoveItem: { _, _, _, _, _, _, _ in S_OK },
            PreCopyItem: { _, _, _, _, _ in S_OK },
            PostCopyItem: { _, _, _, _, _, _, _ in S_OK },
            PreDeleteItem: { this, flags, _ in
                guard flags & ShellRecycleOperation.recycleIfPossible != 0 else {
                    ProgressSink.sinkState(this)?.declined = true
                    return ShellRecycleOperation.abort
                }
                return S_OK
            },
            PostDeleteItem: { this, _, _, result, newItem in
                let seen = ProgressSink.sinkState(this)
                seen?.deleteResult = result
                seen?.newLocation = ProgressSink.filesystemPath(newItem)
                return S_OK
            },
            PreNewItem: { _, _, _, _ in S_OK },
            PostNewItem: { _, _, _, _, _, _, _, _ in S_OK },
            UpdateProgress: { _, _, _ in S_OK },
            ResetTimer: { _ in S_OK },
            PauseTimer: { _ in S_OK },
            ResumeTimer: { _ in S_OK }
        )
    }
}
#endif
