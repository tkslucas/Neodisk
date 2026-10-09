//
//  AppChannel.swift
//  Neodisk
//

/// Which build this is: the stable release, or the nightly that installs
/// beside it (built with `-Xswiftc -DNEODISK_NIGHTLY`). Each has its own
/// name, id and storage, so a nightly never touches the stable app's data.
public enum AppChannel: Sendable {
    case stable
    case nightly

    #if NEODISK_NIGHTLY
    public static let current = AppChannel.nightly
    #else
    public static let current = AppChannel.stable
    #endif

    /// The shown name, also the Application Support folder.
    public var appName: String {
        switch self {
        case .stable: "Neodisk"
        case .nightly: "Neodisk Nightly"
        }
    }

    /// The macOS bundle id and the Linux application id.
    public var identifier: String {
        switch self {
        case .stable: "com.lucastakayasu.Neodisk"
        case .nightly: "com.lucastakayasu.Neodisk.Nightly"
        }
    }

    /// Lowercase name for Linux paths: the binary, its share and config folders.
    public var slug: String {
        switch self {
        case .stable: "neodisk"
        case .nightly: "neodisk-nightly"
        }
    }
}
