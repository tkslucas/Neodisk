// Reads a local NTFS volume's master file table straight off the volume: one sequential pass in large chunks
// instead of one directory read per folder. Read-only: the volume is opened with GENERIC_READ and shared for
// reading and writing, and the only control code sent is FSCTL_GET_NTFS_VOLUME_DATA.

#if os(Windows)
import Dispatch
import Foundation
import WinSDK

nonisolated final class NTFSVolumeReader: @unchecked Sendable {
    struct Geometry: Sendable {
        let bytesPerSector: Int
        let bytesPerCluster: Int
        let recordSize: Int
        let fileTableValidLength: Int64
        let fileTableStartCluster: Int64
        /// The low 32 bits, as GetVolumeInformationW reports it and as directory listings identify the volume.
        let volumeSerial: UInt64

        var recordCount: Int { Int(fileTableValidLength / Int64(recordSize)) }
    }

    enum ReaderError: Error {
        case notLocalNTFS
        case openFailed(DWORD)
        case controlFailed(DWORD)
        case readFailed(DWORD, offset: Int64)
        case badFileTable(String)
    }

    /// The volume's root as Windows names it, `C:\` or a mounted folder's path with a trailing backslash.
    let mountPoint: String
    let geometry: Geometry
    private let handle: HANDLE

    private static let fsctlGetNTFSVolumeData: DWORD = 0x0009_0064
    private static let genericRead: DWORD = 0x8000_0000
    private static let shareReadWrite: DWORD = 0x1 | 0x2
    private static let openExisting: DWORD = 3
    private static let noBuffering: DWORD = 0x2000_0000
    private static let driveRemovable: UINT = 2
    private static let driveFixed: UINT = 3

    private init(mountPoint: String, geometry: Geometry, handle: HANDLE) {
        self.mountPoint = mountPoint
        self.geometry = geometry
        self.handle = handle
    }

    deinit {
        CloseHandle(handle)
    }

    /// The volume holding `path`, when it's a local NTFS volume this process may read raw (elevated).
    static func open(volumeContaining path: String) throws -> NTFSVolumeReader {
        let windowsPath = path.replacingOccurrences(of: "/", with: "\\")
        guard let mountPoint = volumePathName(of: windowsPath) else { throw ReaderError.notLocalNTFS }
        let driveType = mountPoint.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
        guard driveType == driveFixed || driveType == driveRemovable else { throw ReaderError.notLocalNTFS }

        var serial: DWORD = 0
        var fileSystemName = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let gotInformation = mountPoint.withCString(encodedAs: UTF16.self) { root in
            GetVolumeInformationW(root, nil, 0, &serial, nil, nil, &fileSystemName, DWORD(fileSystemName.count))
        }
        guard gotInformation,
              wideString(fileSystemName) == "NTFS",
              let device = volumeDevicePath(of: mountPoint) else {
            throw ReaderError.notLocalNTFS
        }

        let handle = device.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, genericRead, shareReadWrite, nil, openExisting, noBuffering, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw ReaderError.openFailed(GetLastError()) }

        var data = NTFS_VOLUME_DATA_BUFFER()
        var returned: DWORD = 0
        let gotData = DeviceIoControl(
            handle, fsctlGetNTFSVolumeData, nil, 0,
            &data, DWORD(MemoryLayout<NTFS_VOLUME_DATA_BUFFER>.size), &returned, nil
        )
        guard gotData else {
            let error = GetLastError()
            CloseHandle(handle)
            throw ReaderError.controlFailed(error)
        }
        let geometry = Geometry(
            bytesPerSector: Int(data.BytesPerSector),
            bytesPerCluster: Int(data.BytesPerCluster),
            recordSize: Int(data.BytesPerFileRecordSegment),
            fileTableValidLength: data.MftValidDataLength.QuadPart,
            fileTableStartCluster: data.MftStartLcn.QuadPart,
            volumeSerial: UInt64(serial)
        )
        guard geometry.bytesPerSector > 0, geometry.bytesPerCluster >= geometry.bytesPerSector,
              geometry.recordSize >= 1024, geometry.recordSize % NTFSRecordParser.updateSequenceStride == 0,
              geometry.fileTableValidLength >= Int64(geometry.recordSize) * 16 else {
            CloseHandle(handle)
            throw ReaderError.badFileTable("geometry")
        }
        return NTFSVolumeReader(mountPoint: mountPoint, geometry: geometry, handle: handle)
    }

    private static func volumePathName(of path: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let ok = path.withCString(encodedAs: UTF16.self) { GetVolumePathNameW($0, &buffer, DWORD(buffer.count)) }
        guard ok else { return nil }
        let name = wideString(buffer)
        return name.hasSuffix("\\") ? name : name + "\\"
    }

    /// `\\?\Volume{…}` without its trailing backslash: the form CreateFileW opens as the raw volume.
    private static func volumeDevicePath(of mountPoint: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 64)
        let ok = mountPoint.withCString(encodedAs: UTF16.self) {
            GetVolumeNameForVolumeMountPointW($0, &buffer, DWORD(buffer.count))
        }
        guard ok else { return nil }
        var name = wideString(buffer)
        if name.hasSuffix("\\") { name.removeLast() }
        return name
    }

    private static func wideString(_ buffer: [WCHAR]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    // MARK: - Reading

    /// Positional read of whole sectors into sector-aligned memory.
    private func read(into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int64) throws {
        var overlapped = OVERLAPPED()
        overlapped.Offset = DWORD(truncatingIfNeeded: offset)
        overlapped.OffsetHigh = DWORD(truncatingIfNeeded: offset >> 32)
        var transferred: DWORD = 0
        guard ReadFile(handle, buffer, DWORD(count), &transferred, &overlapped) else {
            throw ReaderError.readFailed(GetLastError(), offset: offset)
        }
        guard Int(transferred) == count else { throw ReaderError.readFailed(0, offset: offset) }
    }

    /// Where each part of the file table lives on the volume, from record 0's `$DATA` (and any extension records
    /// its attribute list names).
    private func fileTableRuns() throws -> [NTFSDataRun] {
        let window = roundUp(geometry.recordSize, to: geometry.bytesPerSector)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: window, alignment: 4096)
        defer { buffer.deallocate() }

        func parseRecord(at diskOffset: Int64) throws -> NTFSFileRecord {
            try read(into: buffer, count: window, at: diskOffset)
            let bytes = UnsafeMutableRawBufferPointer(start: buffer, count: geometry.recordSize)
            try NTFSRecordParser.applyFixups(bytes)
            var record = NTFSFileRecord()
            try NTFSRecordParser.parse(UnsafeRawBufferPointer(bytes), into: &record, options: .fileTable)
            return record
        }

        let first = try parseRecord(at: geometry.fileTableStartCluster * Int64(geometry.bytesPerCluster))
        var runs = first.unnamedDataRuns
        guard first.isInUse, first.unnamedData != nil, !runs.isEmpty else {
            throw ReaderError.badFileTable("record 0 has no data")
        }
        if first.hasAttributeList {
            guard first.attributeListIsResident else { throw ReaderError.badFileTable("non-resident attribute list") }
            let segments = Set(first.attributeList
                .filter { $0.type == NTFSAttributeType.data && !$0.isNamed && $0.segment.recordNumber != 0 }
                .map(\.segment.recordNumber))
            for segment in segments.sorted() {
                let offset = Int64(segment) * Int64(geometry.recordSize)
                guard let location = diskLocation(ofFileTableOffset: offset, runs: runs) else {
                    throw ReaderError.badFileTable("extension record \(segment) unmapped")
                }
                let extensionRecord = try parseRecord(at: location.diskOffset)
                runs += extensionRecord.unnamedDataRuns
            }
        }
        runs.sort { $0.startVCN < $1.startVCN }
        var expectedVCN: UInt64 = 0
        for run in runs {
            guard run.startVCN == expectedVCN, run.lcn != nil else { throw ReaderError.badFileTable("gap in runs") }
            expectedVCN += run.clusterCount
        }
        guard Int64(expectedVCN) * Int64(geometry.bytesPerCluster) >= geometry.fileTableValidLength else {
            throw ReaderError.badFileTable("runs end before the valid length")
        }
        return runs
    }

    private func diskLocation(
        ofFileTableOffset offset: Int64,
        runs: [NTFSDataRun]
    ) -> (diskOffset: Int64, contiguousBytes: Int64)? {
        let cluster = Int64(geometry.bytesPerCluster)
        let vcn = UInt64(offset / cluster)
        guard let run = runs.first(where: { vcn >= $0.startVCN && vcn < $0.startVCN + $0.clusterCount }),
              let lcn = run.lcn else {
            return nil
        }
        let within = offset % cluster
        let diskOffset = (lcn + Int64(vcn - run.startVCN)) * cluster + within
        let contiguous = Int64(run.startVCN + run.clusterCount - vcn) * cluster - within
        return (diskOffset, contiguous)
    }

    struct Statistics: Sendable {
        var bytesRead: Int64 = 0
        var chunks = 0
        var tornRecordsReread = 0
        var setupSeconds = 0.0
        var readSeconds = 0.0
        var parseSeconds = 0.0
        /// Torn records and non-resident reparse tags, read one at a time.
        var rereadSeconds = 0.0
        var reparseTagsRead = 0
        var linkSeconds = 0.0
    }

    /// Reads the whole file table in `chunkSize` pieces on reader threads while workers parse the pieces
    /// already read. `progress` gets bytes done and the total, on the calling thread.
    func readIndex(
        chunkSize requestedChunkSize: Int = 16 << 20,
        workerCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        progress: (Int64, Int64) -> Void = { _, _ in },
        cancellationCheck: () throws -> Void = {}
    ) throws -> (index: NTFSVolumeIndex, statistics: Statistics) {
        let setupStart = ContinuousClock.now
        let runs = try fileTableRuns()
        let recordSize = geometry.recordSize
        let recordCount = geometry.recordCount
        let totalBytes = Int64(recordCount) * Int64(recordSize)
        let alignment = max(recordSize, geometry.bytesPerCluster, geometry.bytesPerSector)
        let chunkSize = max(alignment, requestedChunkSize / alignment * alignment)
        let chunkCount = Int((totalBytes + Int64(chunkSize) - 1) / Int64(chunkSize))
        let builder = NTFSVolumeIndexBuilder(
            recordCount: recordCount,
            recordSize: recordSize,
            volumeSerial: geometry.volumeSerial
        )
        let workers = max(1, workerCount)
        let fragments = (0..<workers).map { _ in builder.makeFragment() }
        var statistics = Statistics()
        statistics.setupSeconds = (ContinuousClock.now - setupStart).seconds

        // Two reads in flight keep the disk busy while one finishes; chunks may complete in any order since
        // each record lands at its own number.
        let readerCount = 2
        let pipeline = ChunkPipeline(bufferCount: readerCount + 2, bufferSize: chunkSize, chunkCount: chunkCount)
        defer { pipeline.deallocate() }
        let readStart = ContinuousClock.now
        let readersDone = DispatchGroup()
        for reader in 0..<readerCount {
            readersDone.enter()
            let thread = Thread { [self] in
                defer { readersDone.leave() }
                while let buffer = pipeline.takeEmpty() {
                    guard let chunk = pipeline.claimChunk() else {
                        pipeline.putEmpty(buffer)
                        return
                    }
                    let start = Int64(chunk) * Int64(chunkSize)
                    let length = Int(min(Int64(chunkSize), totalBytes - start))
                    do {
                        try readFileTableRange(start: start, length: length, runs: runs, into: buffer)
                        pipeline.putFilled(.init(buffer: buffer, start: start, length: length))
                    } catch {
                        pipeline.fail(error)
                        return
                    }
                }
            }
            thread.qualityOfService = .userInitiated
            thread.name = "com.neodisk.mft-reader-\(reader)"
            thread.start()
        }

        var parseSeconds = 0.0
        var done: Int64 = 0
        do {
            for _ in 0..<chunkCount {
                try cancellationCheck()
                let filled = try pipeline.takeFilled()
                let parseStart = ContinuousClock.now
                let records = filled.length / recordSize
                let perWorker = (records + workers - 1) / workers
                nonisolated(unsafe) let buffer = filled.buffer
                let firstRecord = UInt64(filled.start / Int64(recordSize))
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let from = min(worker * perWorker, records)
                    let to = min(from + perWorker, records)
                    guard from < to else { return }
                    builder.ingest(
                        UnsafeMutableRawBufferPointer(start: buffer + from * recordSize, count: (to - from) * recordSize),
                        firstRecord: firstRecord + UInt64(from),
                        into: fragments[worker]
                    )
                }
                parseSeconds += (ContinuousClock.now - parseStart).seconds
                pipeline.putEmpty(buffer)
                done += Int64(filled.length)
                statistics.chunks += 1
                progress(done, totalBytes)
            }
        } catch {
            pipeline.cancel()
            readersDone.wait()
            throw error
        }
        pipeline.cancel()
        readersDone.wait()
        statistics.readSeconds = (ContinuousClock.now - readStart).seconds
        statistics.bytesRead = totalBytes
        statistics.parseSeconds = parseSeconds

        // Records torn by a write racing the bulk read get one more read each.
        let rereadStart = ContinuousClock.now
        let torn = builder.tornRecords()
        if !torn.isEmpty {
            builder.clearTornRecords()
            let retry = builder.makeFragment()
            let window = alignment
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: window, alignment: 4096)
            defer { buffer.deallocate() }
            for record in torn {
                let offset = Int64(record) * Int64(recordSize)
                let windowStart = offset / Int64(window) * Int64(window)
                try readFileTableRange(start: windowStart, length: window, runs: runs, into: buffer)
                builder.reingest(
                    UnsafeMutableRawBufferPointer(start: buffer + Int(offset - windowStart), count: recordSize),
                    record: record,
                    into: retry
                )
            }
            statistics.tornRecordsReread = torn.count
        }

        // Reparse buffers too large for the record: one cluster read each for the tag (a handful per volume).
        let reparseClusters = builder.reparseClusters()
        if !reparseClusters.isEmpty {
            let window = roundUp(geometry.bytesPerCluster, to: geometry.bytesPerSector)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: window, alignment: 4096)
            defer { buffer.deallocate() }
            for (record, cluster) in reparseClusters {
                try read(into: buffer, count: window, at: cluster * Int64(geometry.bytesPerCluster))
                builder.setReparseTag(buffer.loadUnaligned(as: UInt32.self), record: record)
            }
            statistics.reparseTagsRead = reparseClusters.count
        }
        statistics.rereadSeconds = (ContinuousClock.now - rereadStart).seconds

        let linkStart = ContinuousClock.now
        let index = try builder.finish()
        statistics.linkSeconds = (ContinuousClock.now - linkStart).seconds
        return (index, statistics)
    }

    /// One logical range of the file table, gathered from however many extents it spans.
    private func readFileTableRange(
        start: Int64,
        length: Int,
        runs: [NTFSDataRun],
        into buffer: UnsafeMutableRawPointer
    ) throws {
        var filled = 0
        while filled < length {
            guard let location = diskLocation(ofFileTableOffset: start + Int64(filled), runs: runs) else {
                throw ReaderError.badFileTable("offset \(start + Int64(filled)) unmapped")
            }
            let count = Int(min(Int64(length - filled), location.contiguousBytes))
            try read(into: buffer + filled, count: count, at: location.diskOffset)
            filled += count
        }
    }

    private func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }
}

/// A few chunk buffers cycling between the reader thread and the parsing loop.
private nonisolated final class ChunkPipeline: @unchecked Sendable {
    struct Filled {
        let buffer: UnsafeMutableRawPointer
        let start: Int64
        let length: Int
    }

    private let condition = NSCondition()
    private var empty: [UnsafeMutableRawPointer]
    private var filled: [Filled] = []
    private var failure: Error?
    private var isCancelled = false
    private var nextChunk = 0
    private let chunkCount: Int
    private let all: [UnsafeMutableRawPointer]

    init(bufferCount: Int, bufferSize: Int, chunkCount: Int) {
        all = (0..<bufferCount).map { _ in UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096) }
        empty = all
        self.chunkCount = chunkCount
    }

    func claimChunk() -> Int? {
        condition.lock()
        defer { condition.unlock() }
        guard nextChunk < chunkCount, !isCancelled else { return nil }
        nextChunk += 1
        return nextChunk - 1
    }

    func deallocate() {
        for buffer in all { buffer.deallocate() }
    }

    func takeEmpty() -> UnsafeMutableRawPointer? {
        condition.lock()
        defer { condition.unlock() }
        while empty.isEmpty && !isCancelled { condition.wait() }
        return isCancelled ? nil : empty.removeLast()
    }

    func putEmpty(_ buffer: UnsafeMutableRawPointer) {
        condition.lock()
        empty.append(buffer)
        condition.broadcast()
        condition.unlock()
    }

    func putFilled(_ chunk: Filled) {
        condition.lock()
        filled.append(chunk)
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        failure = error
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func takeFilled() throws -> Filled {
        condition.lock()
        defer { condition.unlock() }
        while filled.isEmpty && failure == nil { condition.wait() }
        if !filled.isEmpty { return filled.removeFirst() }
        throw failure!
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
