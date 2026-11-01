import Foundation
import Testing
@testable import NeodiskKit

@Suite struct NTFSVolumeIndexTests {
    private typealias Record = SyntheticNTFS.Record

    private static func reference(_ record: UInt64, _ sequence: UInt16 = 1) -> UInt64 {
        NTFSFileReference(record: record, sequence: sequence).rawValue
    }

    private static let root = reference(5, 5)
    private static let users = reference(30, 3)

    /// A small volume: metadata files, a folder with links, extension records, stale and free records.
    private static func volume() -> [Record] {
        var records: [Record] = []
        for number in 0..<16 where number != 5 {
            var meta = Record(number: UInt32(number), sequence: UInt16(number == 0 ? 1 : number))
            meta.attributes = [
                SyntheticNTFS.standardInformation(attributes: 0x06),
                SyntheticNTFS.fileName(parent: root, "$Meta\(number)", namespace: NTFSFileNameNamespace.win32AndDOS),
            ]
            records.append(meta)
        }
        var rootRecord = Record(number: 5, sequence: 5, isDirectory: true)
        rootRecord.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x16),
            SyntheticNTFS.fileName(parent: root, ".", namespace: NTFSFileNameNamespace.win32AndDOS),
        ]
        records.append(rootRecord)

        var usersRecord = Record(number: 30, sequence: 3, isDirectory: true)
        usersRecord.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x01),
            SyntheticNTFS.fileName(parent: root, "Users", namespace: NTFSFileNameNamespace.win32AndDOS),
        ]
        records.append(usersRecord)

        var longName = Record(number: 31)
        longName.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20, lastWrite: 133_100_000_000_000_000),
            SyntheticNTFS.fileName(parent: users, "LONGNA~1.TXT", namespace: NTFSFileNameNamespace.dos),
            SyntheticNTFS.fileName(parent: users, "long name.txt", namespace: NTFSFileNameNamespace.win32),
            SyntheticNTFS.nonResidentData(allocated: 8192, real: 5000),
        ]
        records.append(longName)

        var hardLinked = Record(number: 32, sequence: 4, linkCount: 2)
        hardLinked.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.fileName(parent: users, "linked.dll", namespace: NTFSFileNameNamespace.posix),
            SyntheticNTFS.fileName(parent: root, "linked.dll", namespace: NTFSFileNameNamespace.win32AndDOS),
            SyntheticNTFS.residentData(length: 3),
        ]
        records.append(hardLinked)

        // The base holds only the times; its name and data spilled into record 34.
        var spilledBase = Record(number: 33, sequence: 6)
        spilledBase.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.attributeList([(0x10, 0, reference(33, 6)), (0x30, 0, reference(34, 2)), (0x80, 0, reference(34, 2))]),
        ]
        records.append(spilledBase)
        var spilledExtension = Record(number: 34, sequence: 2, base: reference(33, 6))
        spilledExtension.attributes = [
            SyntheticNTFS.fileName(parent: users, "spilled.bin"),
            SyntheticNTFS.nonResidentData(allocated: 1 << 20, real: 1 << 20, totalAllocated: 65536, flags: 0x8000),
        ]
        records.append(spilledExtension)

        // Its parent reference names a previous generation of Users.
        var stale = Record(number: 35)
        stale.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.fileName(parent: reference(30, 2), "stale.txt"),
        ]
        records.append(stale)

        var free = Record(number: 36, isInUse: false)
        free.attributes = [SyntheticNTFS.fileName(parent: users, "deleted.txt")]
        records.append(free)

        var junction = Record(number: 37, isDirectory: true)
        junction.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x416),
            SyntheticNTFS.fileName(parent: root, "Documents and Settings"),
            SyntheticNTFS.reparsePoint(tag: 0xA000_0003),
        ]
        records.append(junction)

        // An extension that claims a base whose sequence moved on: ignored.
        var orphanExtension = Record(number: 38, base: reference(31, 9))
        orphanExtension.attributes = [SyntheticNTFS.fileName(parent: users, "orphan.txt")]
        records.append(orphanExtension)
        return records
    }

    private static func image(_ records: [Record], count: Int = 64) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: count * SyntheticNTFS.recordSize)
        for record in records {
            let offset = Int(record.number) * SyntheticNTFS.recordSize
            image.replaceSubrange(offset..<(offset + SyntheticNTFS.recordSize), with: record.bytes())
        }
        return image
    }

    /// Ingests the image in two halves on two fragments, like two reader chunks.
    private static func build(_ image: [UInt8], count: Int = 64) -> NTFSVolumeIndexBuilder {
        let builder = NTFSVolumeIndexBuilder(recordCount: count, recordSize: SyntheticNTFS.recordSize, volumeSerial: 0xABCD)
        var image = image
        image.withUnsafeMutableBytes { buffer in
            nonisolated(unsafe) let raw = buffer
            let half = (count / 2) * SyntheticNTFS.recordSize
            DispatchQueue.concurrentPerform(iterations: 2) { part in
                let range = part == 0 ? 0..<half : half..<raw.count
                builder.ingest(
                    UnsafeMutableRawBufferPointer(rebasing: raw[range]),
                    firstRecord: UInt64(range.lowerBound / SyntheticNTFS.recordSize),
                    into: builder.makeFragment()
                )
            }
        }
        return builder
    }

    private func children(_ index: NTFSVolumeIndex, of record: UInt32) -> [String: NTFSIndexEntry] {
        var entries: [String: NTFSIndexEntry] = [:]
        index.forEachChild(of: record) { entries[$0.name] = $0 }
        return entries
    }

    @Test func listsWhatADirectoryListingShows() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let rootChildren = children(index, of: NTFSVolumeIndex.rootRecord)
        // Metadata files and the root's own "." name are never listed.
        #expect(Set(rootChildren.keys) == ["Users", "linked.dll", "Documents and Settings"])

        let users = try #require(rootChildren["Users"])
        #expect(users.isDirectory && users.recordNumber == 30 && users.fileAttributes == 0x11)
        #expect(users.fileReference == Self.users)
        #expect(Set(children(index, of: 30).keys) == ["long name.txt", "linked.dll", "spilled.bin"])

        let longName = try #require(children(index, of: 30)["long name.txt"])
        #expect(longName.logicalSize == 5000 && longName.allocationSize == 8192)
        #expect(longName.lastWriteTime == 133_100_000_000_000_000)
        #expect(longName.fileAttributes == 0x20 && longName.linkCount == 1)
        #expect(longName.fileReference == Self.reference(31))
    }

    @Test func hardLinksAreListedInEachDirectoryWithTheirCount() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let inUsers = try #require(children(index, of: 30)["linked.dll"])
        let inRoot = try #require(children(index, of: NTFSVolumeIndex.rootRecord)["linked.dll"])
        #expect(inUsers.recordNumber == 32 && inRoot.recordNumber == 32)
        #expect(inUsers.linkCount == 2 && inRoot.linkCount == 2)
        #expect(inUsers.fileReference == Self.reference(32, 4))
        #expect(inUsers.logicalSize == 3 && inUsers.allocationSize == 8)
    }

    @Test func extensionRecordsContributeNamesAndData() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let spilled = try #require(children(index, of: 30)["spilled.bin"])
        #expect(spilled.recordNumber == 33)
        #expect(spilled.fileReference == Self.reference(33, 6))
        #expect(spilled.logicalSize == 1 << 20)
        #expect(spilled.allocationSize == 65536)
        #expect(children(index, of: 30)["orphan.txt"] == nil)
    }

    @Test func staleAndFreeRecordsStayOut() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let names = Set(children(index, of: 30).keys)
        #expect(!names.contains("stale.txt") && !names.contains("deleted.txt"))
        #expect(index.inUseRecordCount == Self.volume().filter { $0.isInUse && $0.base == 0 }.count)
    }

    @Test func reparsePointsCarryTheirTagAndStopResolution() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let junction = try #require(children(index, of: NTFSVolumeIndex.rootRecord)["Documents and Settings"])
        #expect(junction.reparseTag == 0xA000_0003 && junction.isDirectory)
        #expect(index.resolve(components: ["Documents and Settings"]) == 37)
        #expect(index.resolve(components: ["Documents and Settings", "anything"]) == nil)
        #expect(!NTFSVolumeIndex.isNameSurrogate(0x9000_601A) && NTFSVolumeIndex.isNameSurrogate(0xA000_000C))
    }

    @Test func resolvesPathsExactlyThenIgnoringCase() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        #expect(index.resolve(components: []) == NTFSVolumeIndex.rootRecord)
        #expect(index.resolve(components: ["Users"]) == 30)
        #expect(index.resolve(components: ["USERS", "Long Name.TXT"]) == 31)
        #expect(index.resolve(components: ["Users", "missing"]) == nil)
        #expect(index.resolve(components: ["Users", "long name.txt", "below a file"]) == nil)
        #expect(index.child(of: 30, named: "long name.txt") == 31)
        #expect(index.child(of: 30, named: "LONGNA~1.TXT") == nil)
    }

    @Test func tornRecordsMustBeReadAgainBeforeFinishing() throws {
        let records = Self.volume()
        var image = Self.image(records)
        let tornOffset = 31 * SyntheticNTFS.recordSize + 1022
        image[tornOffset] ^= 0xFF
        let builder = Self.build(image)
        #expect(builder.tornRecords() == [31])
        #expect(throws: NTFSIndexError.unreadableRecords(count: 1)) { try builder.finish() }

        builder.clearTornRecords()
        var fresh = try #require(records.first { $0.number == 31 }).bytes()
        fresh.withUnsafeMutableBytes { builder.reingest($0, record: 31, into: builder.makeFragment()) }
        let index = try builder.finish()
        #expect(children(index, of: 30)["long name.txt"]?.allocationSize == 8192)
    }

    @Test func aRecordAtTheWrongPositionFailsTheWholeIndex() throws {
        var records = Self.volume()
        var moved = try #require(records.first { $0.number == 31 })
        moved.number = 39
        records.append(moved)
        var image = Self.image(records)
        // Record 39's slot now holds a record whose header says 39 but sits at 40.
        let from = 39 * SyntheticNTFS.recordSize
        let to = 40 * SyntheticNTFS.recordSize
        image.replaceSubrange(to..<(to + SyntheticNTFS.recordSize), with: image[from..<(from + SyntheticNTFS.recordSize)])
        #expect(throws: NTFSIndexError.misplacedRecord(expected: 40, found: 39)) {
            try Self.build(image).finish()
        }
    }

    @Test func listedAttributesFollowWhatDirectoryListingsReport() {
        // System-compressed files list as plain files.
        let wof = NTFSVolumeIndex.listedAttributes(stored: 0x0004_0620, reparseTag: 0x8000_0017, isDirectory: false)
        #expect(wof.attributes == 0x20 && wof.reparseTag == 0)
        let bare = NTFSVolumeIndex.listedAttributes(stored: 0x0004_0000, reparseTag: 0, isDirectory: false)
        #expect(bare.attributes == 0x80)
        let directory = NTFSVolumeIndex.listedAttributes(stored: 0x06, reparseTag: 0, isDirectory: true)
        #expect(directory.attributes == 0x16)
        let junction = NTFSVolumeIndex.listedAttributes(stored: 0x416, reparseTag: 0xA000_0003, isDirectory: true)
        #expect(junction.attributes == 0x416 && junction.reparseTag == 0xA000_0003)
    }

    @Test func theRegistryServesDirectoriesUnderARegisteredVolumeOnly() throws {
        let index = try Self.build(Self.image(Self.volume())).finish()
        let id = NTFSIndexRegistry.register(index, rootPath: "Q:/")
        defer { NTFSIndexRegistry.unregister(id) }
        #expect(NTFSIndexRegistry.directory(atPath: "Q:/")?.record == NTFSVolumeIndex.rootRecord)
        #expect(NTFSIndexRegistry.directory(atPath: "Q:/Users")?.record == 30)
        #expect(NTFSIndexRegistry.directory(atPath: "q:/users/")?.record == 30)
        // A file, a missing folder and another volume all go to the disk reader.
        #expect(NTFSIndexRegistry.directory(atPath: "Q:/Users/long name.txt") == nil)
        #expect(NTFSIndexRegistry.directory(atPath: "Q:/Users/missing") == nil)
        #expect(NTFSIndexRegistry.directory(atPath: "R:/Users") == nil)
        NTFSIndexRegistry.unregister(id)
        #expect(NTFSIndexRegistry.directory(atPath: "Q:/Users") == nil)
    }

    @Test func onlyAWholeVolumeChoosesTheFileTableOnItsOwn() {
        #expect(NTFSScanAccelerator.isVolumeRoot("C:/", mountPoint: "C:\\"))
        #expect(NTFSScanAccelerator.isVolumeRoot("c:", mountPoint: "C:\\"))
        #expect(NTFSScanAccelerator.isVolumeRoot("C:/Mounts/Data", mountPoint: "C:\\Mounts\\Data\\"))
        #expect(!NTFSScanAccelerator.isVolumeRoot("C:/Windows", mountPoint: "C:\\"))
    }
}
