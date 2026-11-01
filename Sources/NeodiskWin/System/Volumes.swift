// The drives a person would pick from File Explorer's This PC: fixed, removable and network volumes with
// media in them, with their labels and capacity.

import Foundation
import WinSDK

struct Volume: Equatable {
    enum Kind: Equatable {
        case fixed, removable, network
    }

    /// The root path, `C:\`.
    let root: String
    let label: String
    let kind: Kind
    let totalBytes: Int64
    let freeBytes: Int64

    /// "Local Disk (C:)", or the label with the drive letter, as File Explorer names them.
    var title: String {
        let letter = String(root.prefix(2))
        let name = label.isEmpty ? (kind == .fixed ? L("Local Disk") : L("Drive")) : label
        return "\(name) (\(letter))"
    }

    var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0
    }
}

enum Volumes {
    static func current() -> [Volume] {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let length = Int(GetLogicalDriveStringsW(DWORD(buffer.count), &buffer))
        guard length > 0, length < buffer.count else { return [] }
        let roots = buffer[..<length].split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
        return roots.compactMap(volume(at:))
    }

    static func volume(at root: String) -> Volume? {
        let type = withWide(root) { GetDriveTypeW($0) }
        let kind: Volume.Kind
        switch Int32(type) {
        case DRIVE_FIXED: kind = .fixed
        case DRIVE_REMOVABLE: kind = .removable
        case DRIVE_REMOTE: kind = .network
        default: return nil
        }
        var free: ULARGE_INTEGER = ULARGE_INTEGER()
        var total: ULARGE_INTEGER = ULARGE_INTEGER()
        // Fails for an empty card reader or a disconnected share: not a volume to offer.
        guard withWide(root, { GetDiskFreeSpaceExW($0, &free, &total, nil) }) else { return nil }
        var label = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        _ = withWide(root) { GetVolumeInformationW($0, &label, DWORD(label.count), nil, nil, nil, nil, 0) }
        return Volume(
            root: root,
            label: String(wideBuffer: label),
            kind: kind,
            totalBytes: Int64(total.QuadPart),
            freeBytes: Int64(free.QuadPart)
        )
    }
}
