// Prototype, not wired into the app: what node IDs as absolute paths cost, and what deriving them from the
// tree's existing parent index plus each node's name would cost instead. Run with diskscan --bench-ids.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc) && arch(x86_64)
/// glibc's mallinfo2().uordblks: bytes malloc has handed out and not had back. Glibc's Swift module leaves out
/// malloc.h, so this calls it through dlsym; on x86-64 a struct this size comes back through a pointer the
/// caller passes first.
private nonisolated func mallocInUse() -> Int {
    typealias MallInfo2 = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    guard let symbol = dlsym(nil, "mallinfo2") else { return 0 }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 10 * 8, alignment: 8)
    defer { buffer.deallocate() }
    _ = unsafeBitCast(symbol, to: MallInfo2.self)(buffer)
    return buffer.load(fromByteOffset: 7 * 8, as: Int.self)
}
#else
private nonisolated func mallocInUse() -> Int { 0 }
#endif

public nonisolated enum PathIDFootprint {
    public static func report(_ store: FileTreeStore) -> String {
        let storage = store.storage
        let nodes = storage.nodes
        let count = nodes.count
        guard count > 1 else { return "ids: tree too small" }
        var lines: [String] = []
        func line(_ text: String) { lines.append(text) }
        func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        func ms(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        }

        // 1. The ID strings as they are today. Strings of 15 UTF-8 bytes or fewer live inline in the record.
        var heapIDs = 0
        var idBytes = 0
        var heapNames = 0
        for node in nodes {
            let length = node.id.utf8.count
            idBytes += length
            if length > 15 { heapIDs += 1 }
            if node.name.utf8.count > 15 { heapNames += 1 }
        }
        line("nodes \(count): ids on the heap \(heapIDs), mean id \(idBytes / count) bytes, names on the heap \(heapNames)")
        line("records: \(megabytes(count * MemoryLayout<FileNodeRecord>.stride)) (\(MemoryLayout<FileNodeRecord>.stride) B each, id is \(MemoryLayout<String>.stride) of them)")

        // Measured, not estimated: fresh copies of every heap ID, and the malloc in-use delta they cause.
        var copies: [String] = []
        copies.reserveCapacity(count)
        let afterReserve = mallocInUse()
        for node in nodes where node.id.utf8.count > 15 {
            copies.append(String(decoding: Array(node.id.utf8), as: UTF8.self))
        }
        let after = mallocInUse()
        let idHeap = after - afterReserve
        line("id strings in malloc: \(megabytes(idHeap)) (\(heapIDs > 0 ? idHeap / heapIDs : 0) B per heap id, measured by copying them all)")
        copies.removeAll()
        let index = count * (MemoryLayout<Int32>.stride + MemoryLayout<UInt32>.stride) * 2 // slots at <= 50% load
        line("path index: ~\(megabytes(index)) slots, node hashes \(megabytes(storage.nodeHashes.count * 8))")

        // 2. Parent index plus name: the parent array already exists, so the ID would cost nothing extra to
        // store. Check that every ID can be rebuilt that way, and time it.
        let rootID = store.rootID
        let separator = rootID.hasSuffix("/") ? "" : "/"
        func rebuiltPath(_ index: Int32) -> String {
            if index == 0 { return rootID }
            var names: [Substring] = []
            var cursor = index
            while cursor > 0 {
                names.append(Substring(nodes[Int(cursor)].name))
                cursor = storage.parentIndices[Int(cursor)]
            }
            var path = rootID + separator
            path.reserveCapacity(path.utf8.count + names.reduce(0) { $0 + $1.utf8.count + 1 })
            for (position, name) in names.reversed().enumerated() {
                if position > 0 { path += "/" }
                path += name
            }
            return path
        }
        var mismatches = 0
        var firstMismatch: String?
        let clock = ContinuousClock()
        var rebuiltBytes = 0
        let rebuildTime = clock.measure {
            for position in 0..<count {
                let path = rebuiltPath(Int32(position))
                rebuiltBytes &+= path.utf8.count
                if path != nodes[position].id {
                    mismatches += 1
                    if firstMismatch == nil { firstMismatch = "\(nodes[position].id) rebuilt as \(path)" }
                }
            }
        }
        line("rebuild every id from parent + name: \(ms(rebuildTime)) total, \(Int(rebuildTime / .nanoseconds(1)) / count) ns each; mismatches \(mismatches)")
        if let firstMismatch { line("  first mismatch: \(firstMismatch)") }

        // 3. Lookup by path: today's hash index against walking the path's components down from the root.
        var paths = nodes.map(\.id)
        var rng = SystemRandomNumberGenerator()
        paths.shuffle(using: &rng)
        var found = 0
        let hashTime = clock.measure {
            for path in paths where storage.index(of: path) != nil { found += 1 }
        }
        // Per-directory name tables, built once: what a tree without path keys would keep for lookups.
        var childByName: [Int32: [Substring: Int32]] = [:]
        let beforeTables = mallocInUse()
        let tableTime = clock.measure {
            for parent in 0..<count where nodes[parent].isDirectory {
                let children = storage.childIndices(of: Int32(parent))
                guard children.count > 8 else { continue }
                var table: [Substring: Int32] = [:]
                table.reserveCapacity(children.count)
                for child in children { table[Substring(nodes[Int(child)].name)] = child }
                childByName[Int32(parent)] = table
            }
        }
        let tableBytes = mallocInUse() - beforeTables
        func walk(_ path: String) -> Int32? {
            guard path.hasPrefix(rootID) else { return nil }
            var cursor: Int32 = 0
            for component in path.dropFirst(rootID.count).split(separator: "/") {
                if let table = childByName[cursor] {
                    guard let next = table[component] else { return nil }
                    cursor = next
                } else {
                    guard let next = storage.childIndices(of: cursor).first(where: { nodes[Int($0)].name == component })
                    else { return nil }
                    cursor = next
                }
            }
            return cursor
        }
        var walked = 0
        let walkTime = clock.measure {
            for path in paths where walk(path) != nil { walked += 1 }
        }
        line("lookup all \(count) paths: hash index \(ms(hashTime)) (\(found) found), component walk \(ms(walkTime)) (\(walked) found) + \(ms(tableTime)) to build name tables for \(childByName.count) big folders (\(megabytes(tableBytes)))")

        // The same walk over one name-sorted copy of the child slots (4 bytes a node), binary-searched.
        let beforeSorted = mallocInUse()
        var sortedSlots = storage.childSlots
        let sortTime = clock.measure {
            for parent in 0..<count {
                let lower = Int(storage.childStarts[parent])
                let upper = Int(storage.childStarts[parent + 1])
                guard upper - lower > 1 else { continue }
                sortedSlots[lower..<upper].sort { nodes[Int($0)].name < nodes[Int($1)].name }
            }
        }
        let sortedBytes = mallocInUse() - beforeSorted
        func sortedWalk(_ path: String) -> Int32? {
            guard path.hasPrefix(rootID) else { return nil }
            var cursor: Int32 = 0
            for component in path.dropFirst(rootID.count).split(separator: "/") {
                var lower = Int(storage.childStarts[Int(cursor)])
                var upper = Int(storage.childStarts[Int(cursor) + 1])
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if nodes[Int(sortedSlots[middle])].name < component { lower = middle + 1 } else { upper = middle }
                }
                guard lower < Int(storage.childStarts[Int(cursor) + 1]),
                      nodes[Int(sortedSlots[lower])].name == component else { return nil }
                cursor = sortedSlots[lower]
            }
            return cursor
        }
        var sortedFound = 0
        let sortedTime = clock.measure {
            for path in paths where sortedWalk(path) != nil { sortedFound += 1 }
        }
        line("  sorted-slot walk \(ms(sortedTime)) (\(sortedFound) found) + \(ms(sortTime)) to sort (\(megabytes(sortedBytes)))")
        line("malloc in use now: \(megabytes(mallocInUse()))")
        return lines.joined(separator: "\n")
    }
}
