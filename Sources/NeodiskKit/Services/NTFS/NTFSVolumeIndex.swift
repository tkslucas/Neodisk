// A volume's parsed master file table, enough to list any directory without touching the disk. Built from raw
// record bytes in parallel chunks; platform-neutral so tests feed it synthetic records.

import Dispatch
import Foundation

/// What a directory listing reports for one name in a directory.
nonisolated struct NTFSIndexEntry: Sendable {
    let name: String
    let recordNumber: UInt32
    /// The record number with its sequence, as the file ID a directory listing reports.
    let fileReference: UInt64
    let isDirectory: Bool
    let fileAttributes: UInt32
    /// Zero when the record has no reparse point.
    let reparseTag: UInt32
    /// FILETIME ticks.
    let lastWriteTime: Int64
    let logicalSize: Int64
    let allocationSize: Int64
    /// Names this record has in directories, 8.3 aliases not counted.
    let linkCount: UInt32
}

nonisolated enum NTFSIndexError: Error, Equatable {
    /// A record header names a different record than the one read at that position: the extent map is wrong.
    case misplacedRecord(expected: UInt64, found: UInt64)
    /// In-use records that stayed torn after a re-read.
    case unreadableRecords(count: Int)
    case missingRoot
}

nonisolated final class NTFSVolumeIndex: @unchecked Sendable {
    static let rootRecord: UInt32 = 5
    /// Records below this are the volume's own metadata files, which directory listings never show.
    static let firstUserRecord: UInt32 = 16
    static let wofReparseTag: UInt32 = 0x8000_0017

    /// The attributes and tag a directory listing shows for what `$STANDARD_INFORMATION` stores, as measured
    /// against FileIdExtdDirectoryInfo on Windows 11: the directory bit comes from the record header, bit 0x40000
    /// is never listed, a file with none reads as FILE_ATTRIBUTE_NORMAL, and the system-compression filter hides
    /// its reparse point and sparse bit, so those files list as plain files.
    static func listedAttributes(
        stored: UInt32,
        reparseTag: UInt32,
        isDirectory: Bool
    ) -> (attributes: UInt32, reparseTag: UInt32) {
        var attributes = stored & ~0x0004_0000
        var tag = reparseTag
        if tag == wofReparseTag {
            attributes &= ~(0x400 | 0x200)
            tag = 0
        }
        if isDirectory {
            attributes |= 0x10
        } else if attributes == 0 {
            attributes = 0x80
        }
        return (attributes, tag)
    }

    let recordCount: Int
    let inUseRecordCount: Int
    let volumeSerial: UInt64

    private let state: [UInt8]
    private let sequence: [UInt16]
    private let attributes: [UInt32]
    private let reparseTags: [UInt32]
    private let lastWriteTimes: [Int64]
    private let logicalSizes: [Int64]
    private let allocationSizes: [Int64]
    private let linkCounts: [UInt16]

    /// Children of record `r` are links `childStarts[r]..<childStarts[r + 1]`.
    private let childStarts: [UInt32]
    private let linkChildren: [UInt32]
    private let linkNameStarts: [UInt32]
    private let linkNameLengths: [UInt8]
    private let names: [UInt16]
    /// Open addressing over (parent, name): link index + 1, zero for an empty slot.
    private let nameSlots: [UInt32]
    private let nameSlotMask: Int

    var linkCount: Int { linkChildren.count }

    fileprivate init(
        recordCount: Int,
        inUseRecordCount: Int,
        volumeSerial: UInt64,
        state: [UInt8],
        sequence: [UInt16],
        attributes: [UInt32],
        reparseTags: [UInt32],
        lastWriteTimes: [Int64],
        logicalSizes: [Int64],
        allocationSizes: [Int64],
        linkCounts: [UInt16],
        childStarts: [UInt32],
        linkChildren: [UInt32],
        linkNameStarts: [UInt32],
        linkNameLengths: [UInt8],
        names: [UInt16]
    ) {
        self.recordCount = recordCount
        self.inUseRecordCount = inUseRecordCount
        self.volumeSerial = volumeSerial
        self.state = state
        self.sequence = sequence
        self.attributes = attributes
        self.reparseTags = reparseTags
        self.lastWriteTimes = lastWriteTimes
        self.logicalSizes = logicalSizes
        self.allocationSizes = allocationSizes
        self.linkCounts = linkCounts
        self.childStarts = childStarts
        self.linkChildren = linkChildren
        self.linkNameStarts = linkNameStarts
        self.linkNameLengths = linkNameLengths
        self.names = names

        var capacity = 16
        while capacity < linkChildren.count * 2 { capacity <<= 1 }
        var slots = [UInt32](repeating: 0, count: capacity)
        let mask = capacity - 1
        for parent in 0..<recordCount {
            let start = Int(childStarts[parent])
            let end = Int(childStarts[parent + 1])
            guard start < end else { continue }
            for link in start..<end {
                let nameStart = Int(linkNameStarts[link])
                let hash = names.withUnsafeBufferPointer {
                    Self.hash(parent: UInt32(parent), name: UnsafeBufferPointer(
                        rebasing: $0[nameStart..<(nameStart + Int(linkNameLengths[link]))]
                    ))
                }
                var slot = Int(truncatingIfNeeded: hash) & mask
                while slots[slot] != 0 { slot = (slot + 1) & mask }
                slots[slot] = UInt32(link + 1)
            }
        }
        nameSlots = slots
        nameSlotMask = mask
    }

    // MARK: - Lookup

    func isInUseDirectory(_ record: UInt32) -> Bool {
        Int(record) < recordCount && state[Int(record)] & State.inUse != 0 && state[Int(record)] & State.directory != 0
    }

    /// The child of `parent` named exactly `name` (NTFS keeps names as given, so a name a listing returned
    /// always matches itself).
    func child(of parent: UInt32, named name: String) -> UInt32? {
        let units = Array(name.utf16)
        return units.withUnsafeBufferPointer { nameUnits -> UInt32? in
            var slot = Int(truncatingIfNeeded: Self.hash(parent: parent, name: nameUnits)) & nameSlotMask
            while true {
                let value = nameSlots[slot]
                if value == 0 { return nil }
                let link = Int(value - 1)
                if linkParent(of: link) == parent, linkName(link, equals: nameUnits) {
                    return linkChildren[link]
                }
                slot = (slot + 1) & nameSlotMask
            }
        }
    }

    /// Exact names first, then a case-insensitive match the way Windows resolves a typed path. Nil when a
    /// component is missing, or names a reparse point or a file before the last component.
    func resolve(components: [String]) -> UInt32? {
        var current = Self.rootRecord
        guard isInUseDirectory(current) else { return nil }
        for component in components where !component.isEmpty {
            guard isInUseDirectory(current), reparseTags[Int(current)] == 0 else { return nil }
            if let exact = child(of: current, named: component) {
                current = exact
                continue
            }
            let folded = component.uppercased()
            var match: UInt32?
            forEachLink(of: current) { link in
                if match == nil, linkNameString(link).uppercased() == folded {
                    match = linkChildren[link]
                }
            }
            guard let match else { return nil }
            current = match
        }
        return current
    }

    func entry(forRecord record: UInt32, name: String) -> NTFSIndexEntry? {
        let index = Int(record)
        guard index < recordCount, state[index] & State.inUse != 0 else { return nil }
        return makeEntry(record: record, name: name)
    }

    /// Every name listed in `directory`, metadata files left out, in no particular order.
    func forEachChild(of directory: UInt32, _ body: (NTFSIndexEntry) throws -> Void) rethrows {
        guard Int(directory) < recordCount else { return }
        let start = Int(childStarts[Int(directory)])
        let end = Int(childStarts[Int(directory) + 1])
        for link in start..<end {
            try body(makeEntry(record: linkChildren[link], name: linkNameString(link)))
        }
    }

    func childCount(of directory: UInt32) -> Int {
        guard Int(directory) < recordCount else { return 0 }
        return Int(childStarts[Int(directory) + 1] - childStarts[Int(directory)])
    }

    private func makeEntry(record: UInt32, name: String) -> NTFSIndexEntry {
        let index = Int(record)
        let isDirectory = state[index] & State.directory != 0
        let listed = Self.listedAttributes(
            stored: attributes[index],
            reparseTag: reparseTags[index],
            isDirectory: isDirectory
        )
        return NTFSIndexEntry(
            name: name,
            recordNumber: record,
            fileReference: NTFSFileReference(record: UInt64(record), sequence: sequence[index]).rawValue,
            isDirectory: isDirectory,
            fileAttributes: listed.attributes,
            reparseTag: listed.reparseTag,
            lastWriteTime: lastWriteTimes[index],
            logicalSize: logicalSizes[index],
            allocationSize: allocationSizes[index],
            linkCount: UInt32(max(linkCounts[index], 1))
        )
    }

    private func forEachLink(of directory: UInt32, _ body: (Int) -> Void) {
        let start = Int(childStarts[Int(directory)])
        let end = Int(childStarts[Int(directory) + 1])
        for link in start..<end { body(link) }
    }

    /// Links are grouped by parent, so a link's parent is the group it falls in.
    private func linkParent(of link: Int) -> UInt32 {
        var low = 0
        var high = recordCount
        let target = UInt32(link)
        while low < high {
            let middle = (low + high) / 2
            if childStarts[middle + 1] <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return UInt32(low)
    }

    private func linkName(_ link: Int, equals units: UnsafeBufferPointer<UInt16>) -> Bool {
        let length = Int(linkNameLengths[link])
        guard length == units.count else { return false }
        let start = Int(linkNameStarts[link])
        for offset in 0..<length where names[start + offset] != units[offset] {
            return false
        }
        return true
    }

    private func linkNameString(_ link: Int) -> String {
        let start = Int(linkNameStarts[link])
        let length = Int(linkNameLengths[link])
        return names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start..<(start + length)]), as: UTF16.self)
        }
    }

    private static func hash(parent: UInt32, name: UnsafeBufferPointer<UInt16>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ (UInt64(parent) &* 0x9E37_79B9_7F4A_7C15)
        for unit in name {
            hash = (hash ^ UInt64(unit)) &* 0x0000_0100_0000_01B3
        }
        return hash ^ (hash >> 29)
    }

    fileprivate enum State {
        static let inUse: UInt8 = 1 << 0
        static let directory: UInt8 = 1 << 1
        static let hasData: UInt8 = 1 << 2
    }
}

/// Collects one volume's records from parallel chunk parses, then links names to parents.
nonisolated final class NTFSVolumeIndexBuilder: @unchecked Sendable {
    /// One worker's share: what can't be written straight into the per-record arrays.
    final class Fragment: @unchecked Sendable {
        fileprivate var links: [RawLink] = []
        fileprivate var names: [UInt16] = []
        fileprivate var extensions: [ExtensionInfo] = []
        /// In-use records whose fixups failed: torn by a concurrent write, worth one re-read.
        var tornRecords: [UInt64] = []
        /// Records whose reparse data isn't resident: the reader fetches the tag from this cluster.
        var reparseClusters: [(record: UInt64, cluster: Int64)] = []
        var misplacedRecord: (expected: UInt64, found: UInt64)?
        fileprivate var record = NTFSFileRecord()

        init() {}
    }

    fileprivate struct RawLink {
        let parent: UInt64
        let child: UInt32
        /// The sequence the owning record expects its base to have (extension records only).
        let baseSequence: UInt16
        let fromExtension: Bool
        let namespace: UInt8
        let nameStart: UInt32
        let nameLength: UInt8
    }

    fileprivate struct ExtensionInfo {
        let base: NTFSFileReference
        let data: NTFSDataSizes?
        let reparseTag: UInt32?
        let hasReparsePoint: Bool
    }

    let recordCount: Int
    let recordSize: Int
    let volumeSerial: UInt64
    /// Raw columns, not arrays: workers write disjoint records at once, which arrays' exclusivity checks forbid.
    private let columns: Columns
    private let lock = NSLock()
    private var fragments: [Fragment] = []

    init(recordCount: Int, recordSize: Int, volumeSerial: UInt64) {
        self.recordCount = recordCount
        self.recordSize = recordSize
        self.volumeSerial = volumeSerial
        columns = Columns(count: recordCount)
    }

    deinit {
        columns.deallocate()
    }

    func makeFragment() -> Fragment {
        let fragment = Fragment()
        lock.lock()
        fragments.append(fragment)
        lock.unlock()
        return fragment
    }

    /// Parses whole records starting at `firstRecord`, fixing them up in place. Chunks may be ingested from
    /// several threads at once as long as each uses its own fragment and the chunks don't overlap.
    func ingest(_ chunk: UnsafeMutableRawBufferPointer, firstRecord: UInt64, into fragment: Fragment) {
        let count = chunk.count / recordSize
        for index in 0..<count {
            let number = firstRecord + UInt64(index)
            guard number < UInt64(recordCount) else { break }
            let bytes = UnsafeMutableRawBufferPointer(
                rebasing: chunk[(index * recordSize)..<((index + 1) * recordSize)]
            )
            ingestRecord(bytes, number: number, fragment: fragment)
        }
    }

    /// Re-parses one record read again after it was torn. Single-threaded, after the bulk pass.
    func reingest(_ bytes: UnsafeMutableRawBufferPointer, record number: UInt64, into fragment: Fragment) {
        ingest(bytes, firstRecord: number, into: fragment)
    }

    private struct Columns {
        let state: UnsafeMutableBufferPointer<UInt8>
        let sequence: UnsafeMutableBufferPointer<UInt16>
        let attributes: UnsafeMutableBufferPointer<UInt32>
        let reparseTags: UnsafeMutableBufferPointer<UInt32>
        let lastWriteTimes: UnsafeMutableBufferPointer<Int64>
        let logicalSizes: UnsafeMutableBufferPointer<Int64>
        let allocationSizes: UnsafeMutableBufferPointer<Int64>

        init(count: Int) {
            func column<T>(_ type: T.Type, _ zero: T) -> UnsafeMutableBufferPointer<T> {
                let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: max(count, 1))
                buffer.initialize(repeating: zero)
                return buffer
            }
            state = column(UInt8.self, 0)
            sequence = column(UInt16.self, 0)
            attributes = column(UInt32.self, 0)
            reparseTags = column(UInt32.self, 0)
            lastWriteTimes = column(Int64.self, 0)
            logicalSizes = column(Int64.self, 0)
            allocationSizes = column(Int64.self, 0)
        }

        func deallocate() {
            state.deallocate()
            sequence.deallocate()
            attributes.deallocate()
            reparseTags.deallocate()
            lastWriteTimes.deallocate()
            logicalSizes.deallocate()
            allocationSizes.deallocate()
        }
    }

    private func ingestRecord(
        _ bytes: UnsafeMutableRawBufferPointer,
        number: UInt64,
        fragment: Fragment
    ) {
        let view = UnsafeRawBufferPointer(bytes)
        // Never-used slots are zero-filled; only a FILE signature is a record.
        guard NTFSRecordParser.u32(view, 0) == NTFSRecordParser.fileSignature else { return }
        let flags = NTFSRecordParser.u16(view, 0x16)
        guard flags & 0x0001 != 0 else { return }
        do {
            try NTFSRecordParser.applyFixups(bytes)
            try NTFSRecordParser.parse(view, into: &fragment.record)
        } catch {
            fragment.tornRecords.append(number)
            return
        }
        let record = fragment.record
        if let header = record.recordNumber, header != number & 0xFFFF_FFFF {
            if fragment.misplacedRecord == nil {
                fragment.misplacedRecord = (number, header)
            }
            return
        }
        let index = Int(number)
        let child = UInt32(truncatingIfNeeded: number)

        if record.isBaseRecord {
            var recordState = NTFSVolumeIndex.State.inUse
            if record.isDirectory { recordState |= NTFSVolumeIndex.State.directory }
            if let data = record.unnamedData {
                recordState |= NTFSVolumeIndex.State.hasData
                columns.logicalSizes[index] = data.logicalSize
                columns.allocationSizes[index] = data.listedAllocationSize
            }
            columns.state[index] = recordState
            columns.sequence[index] = record.sequenceNumber
            columns.attributes[index] = record.fileAttributes
            columns.lastWriteTimes[index] = record.lastWriteTime
            if record.hasReparsePoint {
                columns.reparseTags[index] = record.reparseTag ?? Self.unknownReparseTag
                if record.reparseTag == nil, let cluster = record.reparseDataCluster {
                    fragment.reparseClusters.append((number, cluster))
                }
            }
        } else if record.unnamedData != nil || record.hasReparsePoint {
            if record.hasReparsePoint, record.reparseTag == nil, let cluster = record.reparseDataCluster {
                fragment.reparseClusters.append((record.baseRecord.recordNumber, cluster))
            }
            fragment.extensions.append(ExtensionInfo(
                base: record.baseRecord,
                data: record.unnamedData,
                reparseTag: record.reparseTag,
                hasReparsePoint: record.hasReparsePoint
            ))
        }

        for name in record.fileNames {
            let nameStart = UInt32(fragment.names.count)
            let units = UnsafeRawBufferPointer(rebasing: view[name.nameOffset..<(name.nameOffset + name.nameLength * 2)])
            for offset in 0..<name.nameLength {
                fragment.names.append(NTFSRecordParser.u16(units, offset * 2))
            }
            fragment.links.append(RawLink(
                parent: name.parent.rawValue,
                child: record.isBaseRecord ? child : UInt32(truncatingIfNeeded: record.baseRecord.recordNumber),
                baseSequence: record.baseRecord.sequenceNumber,
                fromExtension: !record.isBaseRecord,
                namespace: name.namespace,
                nameStart: nameStart,
                nameLength: UInt8(truncatingIfNeeded: name.nameLength)
            ))
        }
    }

    /// A reparse point whose data isn't resident: still never followed, tag unknown.
    static let unknownReparseTag: UInt32 = 0xFFFF_FFFF

    /// Records torn in every fragment so far, for the reader to fetch again before `finish`.
    func tornRecords() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return fragments.flatMap(\.tornRecords)
    }

    func reparseClusters() -> [(record: UInt64, cluster: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return fragments.flatMap(\.reparseClusters)
    }

    /// The tag read from a non-resident reparse buffer. Single-threaded, after the bulk pass.
    func setReparseTag(_ tag: UInt32, record: UInt64) {
        guard record < UInt64(recordCount) else { return }
        columns.reparseTags[Int(record)] = tag
    }

    func clearTornRecords() {
        lock.lock()
        for fragment in fragments { fragment.tornRecords.removeAll() }
        lock.unlock()
    }

    func finish() throws -> NTFSVolumeIndex {
        lock.lock()
        let fragments = self.fragments
        lock.unlock()
        if let misplaced = fragments.lazy.compactMap(\.misplacedRecord).first {
            throw NTFSIndexError.misplacedRecord(expected: misplaced.expected, found: misplaced.found)
        }
        let torn = fragments.reduce(0) { $0 + $1.tornRecords.count }
        guard torn == 0 else { throw NTFSIndexError.unreadableRecords(count: torn) }

        let recordCount = self.recordCount
        let state = columns.state
        let sequence = columns.sequence
        let logicalSizes = columns.logicalSizes
        let allocationSizes = columns.allocationSizes
        let reparseTags = columns.reparseTags
        func isLiveBase(_ record: UInt64, sequence expected: UInt16) -> Bool {
            record < UInt64(recordCount) && state[Int(record)] & NTFSVolumeIndex.State.inUse != 0
                && sequence[Int(record)] == expected
        }

        for fragment in fragments {
            for info in fragment.extensions where isLiveBase(info.base.recordNumber, sequence: info.base.sequenceNumber) {
                let index = Int(info.base.recordNumber)
                if let data = info.data, state[index] & NTFSVolumeIndex.State.hasData == 0 {
                    state[index] |= NTFSVolumeIndex.State.hasData
                    logicalSizes[index] = data.logicalSize
                    allocationSizes[index] = data.listedAllocationSize
                }
                if info.hasReparsePoint, reparseTags[index] == 0 {
                    reparseTags[index] = info.reparseTag ?? Self.unknownReparseTag
                }
            }
        }

        // Names count per record before parents are checked: a name whose parent is gone is still a link.
        var linkCounts = [UInt16](repeating: 0, count: recordCount)
        var childCounts = [UInt32](repeating: 0, count: recordCount + 1)
        var totalNameUnits = 0
        for fragment in fragments {
            totalNameUnits += fragment.names.count
            for link in fragment.links where link.namespace != NTFSFileNameNamespace.dos {
                let child = Int(link.child)
                if link.fromExtension, !isLiveBase(UInt64(child), sequence: link.baseSequence) { continue }
                linkCounts[child] &+= 1
                if isListed(link) {
                    childCounts[Int(NTFSFileReference(rawValue: link.parent).recordNumber)] += 1
                }
            }
        }

        var childStarts = [UInt32](repeating: 0, count: recordCount + 1)
        var running: UInt32 = 0
        for record in 0..<recordCount {
            childStarts[record] = running
            running += childCounts[record]
        }
        childStarts[recordCount] = running
        let listedCount = Int(running)

        var fill = childStarts
        var linkChildren = [UInt32](repeating: 0, count: listedCount)
        var linkNameStarts = [UInt32](repeating: 0, count: listedCount)
        var linkNameLengths = [UInt8](repeating: 0, count: listedCount)
        var names: [UInt16] = []
        names.reserveCapacity(totalNameUnits)
        for fragment in fragments {
            let base = UInt32(names.count)
            names.append(contentsOf: fragment.names)
            for link in fragment.links where link.namespace != NTFSFileNameNamespace.dos {
                if link.fromExtension, !isLiveBase(UInt64(link.child), sequence: link.baseSequence) { continue }
                guard isListed(link) else { continue }
                let parent = Int(NTFSFileReference(rawValue: link.parent).recordNumber)
                let slot = Int(fill[parent])
                fill[parent] += 1
                linkChildren[slot] = link.child
                linkNameStarts[slot] = base + link.nameStart
                linkNameLengths[slot] = link.nameLength
            }
        }

        let inUse = state.reduce(0) { $0 + Int($1 & NTFSVolumeIndex.State.inUse) }
        guard Int(NTFSVolumeIndex.rootRecord) < recordCount,
              state[Int(NTFSVolumeIndex.rootRecord)] & NTFSVolumeIndex.State.directory != 0 else {
            throw NTFSIndexError.missingRoot
        }
        return NTFSVolumeIndex(
            recordCount: recordCount,
            inUseRecordCount: inUse,
            volumeSerial: volumeSerial,
            state: Array(state.prefix(recordCount)),
            sequence: Array(sequence.prefix(recordCount)),
            attributes: Array(columns.attributes.prefix(recordCount)),
            reparseTags: Array(reparseTags.prefix(recordCount)),
            lastWriteTimes: Array(columns.lastWriteTimes.prefix(recordCount)),
            logicalSizes: Array(logicalSizes.prefix(recordCount)),
            allocationSizes: Array(allocationSizes.prefix(recordCount)),
            linkCounts: linkCounts,
            childStarts: childStarts,
            linkChildren: linkChildren,
            linkNameStarts: linkNameStarts,
            linkNameLengths: linkNameLengths,
            names: names
        )
    }

    /// Shown in its parent's listing: the parent is a live directory of the referenced generation, and the
    /// child isn't a metadata file.
    private func isListed(_ link: RawLink) -> Bool {
        let state = columns.state
        let sequence = columns.sequence
        guard link.child >= NTFSVolumeIndex.firstUserRecord, Int(link.child) < recordCount,
              state[Int(link.child)] & NTFSVolumeIndex.State.inUse != 0 else {
            return false
        }
        let parent = NTFSFileReference(rawValue: link.parent)
        guard parent.recordNumber < UInt64(recordCount) else { return false }
        let parentIndex = Int(parent.recordNumber)
        return state[parentIndex] & NTFSVolumeIndex.State.inUse != 0
            && state[parentIndex] & NTFSVolumeIndex.State.directory != 0
            && sequence[parentIndex] == parent.sequenceNumber
    }
}
