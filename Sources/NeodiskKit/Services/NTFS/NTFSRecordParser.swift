// NTFS master file table records, parsed from raw bytes. Platform-neutral so tests run everywhere; only the
// volume reader that feeds it is Windows-only. Every offset is bounds-checked: a torn or garbled record throws,
// it never traps.

import Foundation

/// The record number in the low 48 bits, the record's reuse sequence in the high 16.
nonisolated struct NTFSFileReference: Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(record: UInt64, sequence: UInt16) {
        rawValue = (record & 0xFFFF_FFFF_FFFF) | UInt64(sequence) << 48
    }

    var recordNumber: UInt64 { rawValue & 0xFFFF_FFFF_FFFF }
    var sequenceNumber: UInt16 { UInt16(truncatingIfNeeded: rawValue >> 48) }
}

nonisolated enum NTFSAttributeType {
    static let standardInformation: UInt32 = 0x10
    static let attributeList: UInt32 = 0x20
    static let fileName: UInt32 = 0x30
    static let data: UInt32 = 0x80
    static let reparsePoint: UInt32 = 0xC0
    static let end: UInt32 = 0xFFFF_FFFF
}

nonisolated enum NTFSFileNameNamespace {
    static let posix: UInt8 = 0
    static let win32: UInt8 = 1
    /// The 8.3 alias of a long name; directory listings never show it on its own.
    static let dos: UInt8 = 2
    static let win32AndDOS: UInt8 = 3
}

nonisolated enum NTFSRecordError: Error, Equatable {
    case badSignature
    /// A sector's last two bytes don't carry the update sequence number: the record was torn mid-write.
    case badFixup
    case truncated
    case badAttribute
    case badDataRun
}

/// One extent of a non-resident attribute: `clusterCount` clusters starting at `lcn`, or a hole when nil.
nonisolated struct NTFSDataRun: Equatable, Sendable {
    let startVCN: UInt64
    let clusterCount: UInt64
    let lcn: Int64?
}

/// The unnamed `$DATA` stream's sizes from the extent that starts at VCN 0, the only one that carries them.
nonisolated struct NTFSDataSizes: Equatable, Sendable {
    var logicalSize: Int64
    /// Non-resident: the clusters reserved for the stream. Resident: the value length.
    var allocatedSize: Int64
    /// Compressed or sparse streams only: the clusters actually in use.
    var totalAllocated: Int64?
    var isResident: Bool
    var isCompressed: Bool
    var isSparse: Bool

    /// What a directory listing reports as AllocationSize for this stream: the clusters in use for compressed
    /// and sparse streams, the reservation otherwise, and the 8-byte-aligned value length for resident data.
    var listedAllocationSize: Int64 {
        if isResident {
            return (allocatedSize + 7) & ~7
        }
        return totalAllocated ?? allocatedSize
    }
}

nonisolated struct NTFSFileNameSlice: Equatable, Sendable {
    let parent: NTFSFileReference
    let namespace: UInt8
    /// Byte offset of the UTF-16LE name inside the record buffer.
    let nameOffset: Int
    /// In UTF-16 code units.
    let nameLength: Int
}

nonisolated struct NTFSAttributeListEntry: Equatable, Sendable {
    let type: UInt32
    let lowestVCN: UInt64
    let segment: NTFSFileReference
    let isNamed: Bool
}

/// One FILE record segment. Reused across records on the hot path: `NTFSRecordParser.parse` resets it and keeps
/// the arrays' capacity.
nonisolated struct NTFSFileRecord: Sendable {
    /// From the header, when the record carries one (every NTFS 3.1 volume does).
    var recordNumber: UInt64?
    var sequenceNumber: UInt16 = 0
    /// The header's count of names in directory indexes.
    var hardLinkCount: UInt16 = 0
    var isInUse = false
    var isDirectory = false
    /// Zero for a base record; an extension record points at the base record that owns it.
    var baseRecord = NTFSFileReference(rawValue: 0)
    var hasStandardInformation = false
    var fileAttributes: UInt32 = 0
    /// FILETIME ticks (100 ns since 1601-01-01 UTC).
    var creationTime: Int64 = 0
    var lastWriteTime: Int64 = 0
    var fileNames: [NTFSFileNameSlice] = []
    var unnamedData: NTFSDataSizes?
    /// Extents of the unnamed `$DATA` in this record (any VCN range), decoded only when asked.
    var unnamedDataRuns: [NTFSDataRun] = []
    var hasReparsePoint = false
    /// Nil when the reparse data is non-resident (rare: only very large reparse buffers).
    var reparseTag: UInt32?
    var hasAttributeList = false
    /// Resident attribute lists only, decoded only when asked.
    var attributeList: [NTFSAttributeListEntry] = []
    var attributeListIsResident = true

    var isBaseRecord: Bool { baseRecord.rawValue == 0 }

    mutating func reset() {
        recordNumber = nil
        sequenceNumber = 0
        hardLinkCount = 0
        isInUse = false
        isDirectory = false
        baseRecord = NTFSFileReference(rawValue: 0)
        hasStandardInformation = false
        fileAttributes = 0
        creationTime = 0
        lastWriteTime = 0
        fileNames.removeAll(keepingCapacity: true)
        unnamedData = nil
        unnamedDataRuns.removeAll(keepingCapacity: true)
        hasReparsePoint = false
        reparseTag = nil
        hasAttributeList = false
        attributeList.removeAll(keepingCapacity: true)
        attributeListIsResident = true
    }
}

nonisolated enum NTFSRecordParser {
    /// The update sequence covers every 512 bytes regardless of the disk's sector size.
    static let updateSequenceStride = 512
    static let fileSignature: UInt32 = 0x454C_4946 // "FILE"

    struct Options: Sendable {
        var decodeDataRuns = false
        var decodeAttributeList = false

        static let index = Options()
        static let fileTable = Options(decodeDataRuns: true, decodeAttributeList: true)
    }

    /// Restores the sector tails the update sequence array saved. Throws `badFixup` on a torn record.
    static func applyFixups(_ record: UnsafeMutableRawBufferPointer) throws {
        guard record.count >= 0x30, record.count % updateSequenceStride == 0 else { throw NTFSRecordError.truncated }
        let view = UnsafeRawBufferPointer(record)
        guard u32(view, 0) == fileSignature else { throw NTFSRecordError.badSignature }
        let arrayOffset = Int(u16(view, 4))
        let arrayCount = Int(u16(view, 6))
        guard arrayCount == record.count / updateSequenceStride + 1,
              arrayOffset >= 0x28, arrayOffset % 2 == 0,
              arrayOffset + arrayCount * 2 <= record.count else {
            throw NTFSRecordError.badFixup
        }
        let check = u16(view, arrayOffset)
        for sector in 1..<arrayCount {
            let tail = sector * updateSequenceStride - 2
            guard u16(view, tail) == check else { throw NTFSRecordError.badFixup }
            record.storeBytes(of: u16(view, arrayOffset + sector * 2), toByteOffset: tail, as: UInt16.self)
        }
    }

    /// Fixups must already be applied. A record not in use is returned with only its header fields.
    static func parse(
        _ bytes: UnsafeRawBufferPointer,
        into record: inout NTFSFileRecord,
        options: Options = .index
    ) throws {
        record.reset()
        guard bytes.count >= 0x30 else { throw NTFSRecordError.truncated }
        guard u32(bytes, 0) == fileSignature else { throw NTFSRecordError.badSignature }
        let arrayOffset = Int(u16(bytes, 4))
        record.sequenceNumber = u16(bytes, 0x10)
        record.hardLinkCount = u16(bytes, 0x12)
        let firstAttribute = Int(u16(bytes, 0x14))
        let flags = u16(bytes, 0x16)
        let usedSize = Int(u32(bytes, 0x18))
        record.baseRecord = NTFSFileReference(rawValue: u64(bytes, 0x20))
        record.isInUse = flags & 0x0001 != 0
        record.isDirectory = flags & 0x0002 != 0
        if arrayOffset >= 0x30 {
            record.recordNumber = UInt64(u32(bytes, 0x2C))
        }
        guard record.isInUse else { return }
        guard usedSize <= bytes.count, firstAttribute >= 0x18, firstAttribute + 4 <= usedSize else {
            throw NTFSRecordError.truncated
        }

        var offset = firstAttribute
        while true {
            guard offset + 4 <= usedSize else { throw NTFSRecordError.truncated }
            let type = u32(bytes, offset)
            if type == NTFSAttributeType.end { break }
            guard offset + 0x18 <= usedSize else { throw NTFSRecordError.badAttribute }
            let length = Int(u32(bytes, offset + 4))
            guard length >= 0x18, length % 8 == 0, offset + length <= usedSize else {
                throw NTFSRecordError.badAttribute
            }
            let attribute = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + length)])
            try parseAttribute(
                type: type,
                attribute,
                recordOffset: offset,
                into: &record,
                options: options
            )
            offset += length
        }
    }

    private static func parseAttribute(
        type: UInt32,
        _ attribute: UnsafeRawBufferPointer,
        recordOffset: Int,
        into record: inout NTFSFileRecord,
        options: Options
    ) throws {
        let isNonResident = attribute[8] != 0
        let nameLength = Int(attribute[9])
        let nameOffset = Int(u16(attribute, 10))
        let flags = u16(attribute, 12)
        if nameLength > 0 {
            guard nameOffset + nameLength * 2 <= attribute.count else { throw NTFSRecordError.badAttribute }
        }

        switch type {
        case NTFSAttributeType.standardInformation:
            let value = try residentValue(attribute, isNonResident: isNonResident)
            guard value.count >= 0x24 else { throw NTFSRecordError.badAttribute }
            record.hasStandardInformation = true
            record.creationTime = Int64(bitPattern: u64(value, 0x00))
            record.lastWriteTime = Int64(bitPattern: u64(value, 0x08))
            record.fileAttributes = u32(value, 0x20)

        case NTFSAttributeType.attributeList:
            record.hasAttributeList = true
            guard !isNonResident else {
                record.attributeListIsResident = false
                return
            }
            guard options.decodeAttributeList else { return }
            let value = try residentValue(attribute, isNonResident: false)
            try decodeAttributeList(value, into: &record.attributeList)

        case NTFSAttributeType.fileName:
            let value = try residentValue(attribute, isNonResident: isNonResident)
            guard value.count >= 0x42 else { throw NTFSRecordError.badAttribute }
            let characters = Int(value[0x40])
            guard 0x42 + characters * 2 <= value.count, characters > 0 else { throw NTFSRecordError.badAttribute }
            let valueOffset = Int(u16(attribute, 0x14))
            record.fileNames.append(NTFSFileNameSlice(
                parent: NTFSFileReference(rawValue: u64(value, 0)),
                namespace: value[0x41],
                nameOffset: recordOffset + valueOffset + 0x42,
                nameLength: characters
            ))

        case NTFSAttributeType.data where nameLength == 0:
            let isCompressed = flags & 0x0001 != 0
            let isSparse = flags & 0x8000 != 0
            if !isNonResident {
                let value = try residentValue(attribute, isNonResident: false)
                record.unnamedData = NTFSDataSizes(
                    logicalSize: Int64(value.count),
                    allocatedSize: Int64(value.count),
                    totalAllocated: nil,
                    isResident: true,
                    isCompressed: isCompressed,
                    isSparse: isSparse
                )
                return
            }
            guard attribute.count >= 0x40 else { throw NTFSRecordError.badAttribute }
            let lowestVCN = u64(attribute, 0x10)
            if lowestVCN == 0 {
                let hasTotalAllocated = (isCompressed || isSparse) && attribute.count >= 0x48
                    && Int(u16(attribute, 0x20)) >= 0x48
                record.unnamedData = NTFSDataSizes(
                    logicalSize: Int64(bitPattern: u64(attribute, 0x30)),
                    allocatedSize: Int64(bitPattern: u64(attribute, 0x28)),
                    totalAllocated: hasTotalAllocated ? Int64(bitPattern: u64(attribute, 0x40)) : nil,
                    isResident: false,
                    isCompressed: isCompressed,
                    isSparse: isSparse
                )
            }
            if options.decodeDataRuns {
                let runsOffset = Int(u16(attribute, 0x20))
                guard runsOffset >= 0x40, runsOffset <= attribute.count else { throw NTFSRecordError.badAttribute }
                try decodeDataRuns(
                    UnsafeRawBufferPointer(rebasing: attribute[runsOffset...]),
                    startingVCN: lowestVCN,
                    into: &record.unnamedDataRuns
                )
            }

        case NTFSAttributeType.reparsePoint:
            record.hasReparsePoint = true
            if !isNonResident {
                let value = try residentValue(attribute, isNonResident: false)
                if value.count >= 4 {
                    record.reparseTag = u32(value, 0)
                }
            }

        default:
            break
        }
    }

    private static func residentValue(
        _ attribute: UnsafeRawBufferPointer,
        isNonResident: Bool
    ) throws -> UnsafeRawBufferPointer {
        guard !isNonResident else { throw NTFSRecordError.badAttribute }
        let valueLength = Int(u32(attribute, 0x10))
        let valueOffset = Int(u16(attribute, 0x14))
        guard valueOffset >= 0x18, valueOffset + valueLength <= attribute.count else {
            throw NTFSRecordError.badAttribute
        }
        return UnsafeRawBufferPointer(rebasing: attribute[valueOffset..<(valueOffset + valueLength)])
    }

    static func decodeAttributeList(
        _ value: UnsafeRawBufferPointer,
        into entries: inout [NTFSAttributeListEntry]
    ) throws {
        var offset = 0
        while offset + 0x1A <= value.count {
            let length = Int(u16(value, offset + 4))
            guard length >= 0x1A, offset + length <= value.count else { throw NTFSRecordError.badAttribute }
            entries.append(NTFSAttributeListEntry(
                type: u32(value, offset),
                lowestVCN: u64(value, offset + 8),
                segment: NTFSFileReference(rawValue: u64(value, offset + 0x10)),
                isNamed: value[offset + 6] != 0
            ))
            offset += length
        }
    }

    /// Mapping pairs: a header byte whose low nibble sizes the run length and high nibble the signed LCN delta
    /// (zero: a hole), then those bytes little-endian, until a zero header.
    static func decodeDataRuns(
        _ bytes: UnsafeRawBufferPointer,
        startingVCN: UInt64,
        into runs: inout [NTFSDataRun]
    ) throws {
        var position = 0
        var vcn = startingVCN
        var lcn: Int64 = 0
        while position < bytes.count {
            let header = bytes[position]
            if header == 0 { return }
            let lengthSize = Int(header & 0x0F)
            let offsetSize = Int(header >> 4)
            guard (1...8).contains(lengthSize), offsetSize <= 8,
                  position + 1 + lengthSize + offsetSize <= bytes.count else {
                throw NTFSRecordError.badDataRun
            }
            var length: UInt64 = 0
            for index in 0..<lengthSize {
                length |= UInt64(bytes[position + 1 + index]) << (8 * index)
            }
            guard length > 0, length < 1 << 48 else { throw NTFSRecordError.badDataRun }
            if offsetSize == 0 {
                runs.append(NTFSDataRun(startVCN: vcn, clusterCount: length, lcn: nil))
            } else {
                var delta: UInt64 = 0
                for index in 0..<offsetSize {
                    delta |= UInt64(bytes[position + 1 + lengthSize + index]) << (8 * index)
                }
                let shift = UInt64(64 - 8 * offsetSize)
                let signedDelta = Int64(bitPattern: delta << shift) >> Int64(shift)
                let (next, overflow) = lcn.addingReportingOverflow(signedDelta)
                guard !overflow, next >= 0 else { throw NTFSRecordError.badDataRun }
                lcn = next
                runs.append(NTFSDataRun(startVCN: vcn, clusterCount: length, lcn: lcn))
            }
            vcn += length
            position += 1 + lengthSize + offsetSize
        }
        throw NTFSRecordError.badDataRun
    }

    @inline(__always)
    static func u16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    static func u32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    static func u64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
