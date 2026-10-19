#if canImport(Darwin)
import Darwin
#endif
import Dispatch
import Foundation

/// Sandbox and group containers: more than two opens in flight inside them can stall one for 5-6 s
/// (macOS 26), so reads are capped at `concurrentReadLimit` on their own traversal lane.
nonisolated enum ProtectedContainers {
    static let concurrentReadLimit = 2

    private static let gate = DispatchSemaphore(value: concurrentReadLimit)

    /// Whether `path` lies inside a container (not the container folders
    /// themselves).
    static func contains(_ path: String) -> Bool {
        #if canImport(Darwin)
        var path = path
        return path.withUTF8 { bytes in
            contains(bytes, "/Library/Containers/") || contains(bytes, "/Library/Group Containers/")
        }
        #else
        return false
        #endif
    }

    /// Byte search; `String.contains` is Foundation's and ran hot here.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return memmem(base, bytes.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// Whether the children of the directory at `path` lie inside a container.
    static func containsChildren(ofDirectory path: String) -> Bool {
        #if canImport(Darwin)
        return path.hasSuffix("/Library/Containers") || path.hasSuffix("/Library/Group Containers")
            || contains(path)
        #else
        return false
        #endif
    }

    /// Runs `body` holding one of the container read slots when `path` is
    /// inside a container, and directly otherwise.
    static func withReadSlot<Result>(forDirectory path: String, _ body: () throws -> Result) rethrows -> Result {
        guard contains(path) else { return try body() }
        gate.wait()
        defer { gate.signal() }
        return try body()
    }
}
