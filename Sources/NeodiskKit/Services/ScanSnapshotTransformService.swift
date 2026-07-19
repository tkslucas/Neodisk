//
//  ScanSnapshotTransformService.swift
//  Neodisk
//

import Foundation

public protocol ScanSnapshotTransforming: Sendable {
    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot?

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot?
}

public actor ScanSnapshotTransformService {
    public init() {}

    public func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning] = []
    ) async throws -> ScanSnapshot? {
        try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    public func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try snapshot.scoped(
            to: target,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

extension ScanSnapshotTransformService: ScanSnapshotTransforming {}
