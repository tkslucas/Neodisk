//
//  FileNodeRecordStorageTests.swift
//  NeodiskKitTests
//
//  FileNodeRecord keeps its public fields while storing them compactly: a
//  large scan holds millions of records, so the stride is a budget, and
//  every field must read back exactly what was stored — including the
//  rarely set ones that live in the side object.
//

import Foundation
import Testing
@testable import NeodiskKit

@Suite struct FileNodeRecordStorageTests {
    private func record(
        id: String = "/a/b",
        path: String? = nil,
        isDirectory: Bool = false,
        allocatedSize: Int64 = 4096,
        unduplicatedAllocatedSize: Int64? = nil,
        lastModified: Date? = Date(timeIntervalSinceReferenceDate: 812_345_678.25),
        fileIdentity: FileIdentity? = .fileSystem(device: 7, inode: 123_456_789_012),
        isDataless: Bool = false,
        cloudOnlyLogicalSize: Int64? = nil,
        cloneInfo: CloneInfo? = nil
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path ?? id,
            name: "b",
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: 5000,
            descendantFileCount: isDirectory ? 42 : 0,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: 3,
            isPackage: true,
            isAccessible: false,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo
        )
    }

    @Test func strideStaysWithinBudget() {
        #expect(MemoryLayout<FileNodeRecord>.stride <= 104)
    }

    @Test func commonFieldsRoundTrip() {
        let node = record()
        #expect(node.path == "/a/b")
        #expect(node.lastModified == Date(timeIntervalSinceReferenceDate: 812_345_678.25))
        #expect(node.fileIdentity == .fileSystem(device: 7, inode: 123_456_789_012))
        #expect(node.linkCount == 3)
        #expect(node.unduplicatedAllocatedSize == 4096)
        #expect(node.cloudOnlyLogicalSize == 0)
        #expect(node.cloneInfo == nil)
        #expect(node.isPackage && !node.isAccessible && node.isSelfAccessible && node.isAutoSummarized)
        #expect(!node.isDirectory && !node.isSymbolicLink && !node.isSynthetic && !node.isDataless)
    }

    @Test func missingDateAndIdentityStayMissing() {
        let node = record(lastModified: nil, fileIdentity: nil)
        #expect(node.lastModified == nil)
        #expect(node.fileIdentity == nil)
    }

    @Test func rareFieldsRoundTrip() {
        let data = Data("provider:file".utf8)
        let clone = CloneInfo(device: 7, cloneID: 9, refCount: 2, privateSize: 100)
        let node = record(
            path: "/other/b",
            unduplicatedAllocatedSize: 8192,
            fileIdentity: FileIdentity.resourceIdentifier(data),
            cloneInfo: clone
        )
        #expect(node.path == "/other/b")
        #expect(node.unduplicatedAllocatedSize == 8192)
        #expect(node.fileIdentity == .resourceIdentifier(data))
        #expect(node.cloneInfo == clone)
    }

    @Test func datalessFileDefaultsItsCloudShare() {
        let file = record(isDataless: true)
        #expect(file.isDataless)
        #expect(file.cloudOnlyLogicalSize == 5000)
        // Directories are never dataless and never carry clone info.
        let directory = record(isDirectory: true, isDataless: true, cloneInfo: CloneInfo(device: 7, cloneID: 1, refCount: 2))
        #expect(!directory.isDataless)
        #expect(directory.cloneInfo == nil)
        #expect(directory.descendantFileCount == 42)
    }
}
