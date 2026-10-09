//
//  MemoryFootprint.swift
//  Neodisk
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The process's memory as the system charges it: physical footprint on macOS
/// (Activity Monitor's Memory column), resident set size on Linux.
public nonisolated enum MemoryFootprint {
    public struct Reading: Sendable, Equatable {
        public let current: UInt64
        public let peak: UInt64
    }

    public static func read() -> Reading? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Reading(current: info.phys_footprint, peak: UInt64(max(info.ledger_phys_footprint_peak, 0)))
        #else
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return nil }
        func kilobytes(_ key: String) -> UInt64? {
            status.split(separator: "\n").first { $0.hasPrefix(key) }
                .flatMap { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first }
                .flatMap { UInt64($0) }
        }
        guard let rss = kilobytes("VmRSS:") else { return nil }
        return Reading(current: rss * 1024, peak: (kilobytes("VmHWM:") ?? rss) * 1024)
        #endif
    }

    /// `memory 254 MB (peak 282 MB)`, for log lines.
    public static func summary() -> String {
        guard let reading = read() else { return "memory unknown" }
        return "memory \(megabytes(reading.current)) MB (peak \(megabytes(reading.peak)) MB)"
    }

    public static func megabytes(_ bytes: UInt64) -> UInt64 { bytes / 1_048_576 }
}
