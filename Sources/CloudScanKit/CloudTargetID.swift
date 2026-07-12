//
//  CloudTargetID.swift
//  Neodisk
//
//  Identity scheme for remote cloud scans. A connected account is a
//  ScanTarget whose id/url is "cloudscan://<provider>/<account>"; every
//  node inside it is "<target-id>#<provider-file-id>". File IDs are stable
//  across renames and moves, unlike display paths.
//

import Foundation
import NeodiskKit

public enum CloudTargetID {
    public static let scheme = "cloudscan"

    /// Separates the target prefix from the provider file ID in node IDs.
    static let nodeSeparator: Character = "#"

    public nonisolated static func targetID(providerID: String, accountID: String) -> String {
        "\(scheme)://\(providerID)/\(accountID)"
    }

    public nonisolated static func isCloudTargetID(_ id: String) -> Bool {
        id.hasPrefix("\(scheme)://")
    }

    public nonisolated static func parse(
        _ targetID: String
    ) -> (providerID: String, accountID: String)? {
        let prefix = "\(scheme)://"
        guard targetID.hasPrefix(prefix) else { return nil }
        let remainder = targetID.dropFirst(prefix.count)
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let providerID = String(remainder[..<slash])
        let accountID = String(remainder[remainder.index(after: slash)...])
        guard !providerID.isEmpty, !accountID.isEmpty else { return nil }
        return (providerID, accountID)
    }

    /// The sidebar/scan target for a connected account. Returns nil only for
    /// account identifiers that cannot form a valid URL.
    public nonisolated static func target(
        providerID: String,
        accountID: String,
        displayName: String
    ) -> ScanTarget? {
        let id = targetID(providerID: providerID, accountID: accountID)
        guard let url = URL(string: id) else { return nil }
        return ScanTarget(id: id, url: url, displayName: displayName, kind: .cloud)
    }

    public nonisolated static func nodeID(targetID: String, fileID: String) -> String {
        "\(targetID)\(nodeSeparator)\(fileID)"
    }

    /// Recovers the provider file ID from a node's FileIdentity payload,
    /// written as "<provider>:<file-id>".
    public nonisolated static func fileID(
        fromIdentity identity: FileIdentity?,
        providerID: String
    ) -> String? {
        guard case .resourceIdentifier(let data) = identity,
              let string = String(data: data, encoding: .utf8),
              string.hasPrefix("\(providerID):") else { return nil }
        return String(string.dropFirst(providerID.count + 1))
    }

    public nonisolated static func identity(providerID: String, fileID: String) -> FileIdentity {
        .resourceIdentifier(Data("\(providerID):\(fileID)".utf8))
    }
}
