//
//  DisplayNameOrder.swift
//  Neodisk
//
//  The name tie-break of the child display order (largest first, then by
//  name), in one place so every path that sorts children — assembly,
//  splices, rebuilds, the treemap layout — agrees on it.
//
//  Apple platforms use Finder's `localizedStandardCompare`. Off Darwin that
//  call goes through ICU collation and costs microseconds each; ties are
//  the common case on Linux (thousands of files allocate exactly 4 KB), so
//  it dominated scan assembly — 1.8 s of a 2.3 s scan. There the tie-break
//  is a byte-level natural order instead: ASCII case-insensitive, digit
//  runs compared by value ("file2" < "file10"), with a deterministic final
//  tie-break so distinct names never compare equal.
//

import Foundation

public enum DisplayNameOrder {
    /// Whether `lhs` sorts before `rhs`.
    @inline(__always)
    public nonisolated static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        #if canImport(Darwin)
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
        #else
        return naturalOrder(lhs, rhs) < 0
        #endif
    }

    #if canImport(Darwin)
    /// `precedes` for names already bridged: the `String` form bridges both
    /// names to NSString on every comparison, which a sort with many
    /// equal-sized entries repeats n log n times.
    @inline(__always)
    nonisolated static func precedes(_ lhs: NSString, _ rhs: NSString) -> Bool {
        lhs.localizedStandardCompare(rhs as String) == .orderedAscending
    }
    #endif

    /// Negative, zero, or positive as `lhs` sorts before, equal to, or after
    /// `rhs` in natural order.
    public nonisolated static func naturalOrder(_ lhs: String, _ rhs: String) -> Int {
        var lhs = lhs
        var rhs = rhs
        return lhs.withUTF8 { a in
            rhs.withUTF8 { b in naturalOrder(a, b) }
        }
    }

    private nonisolated static func naturalOrder(
        _ a: UnsafeBufferPointer<UInt8>,
        _ b: UnsafeBufferPointer<UInt8>
    ) -> Int {
        var i = 0
        var j = 0
        // The first difference that only case or leading zeros made; decides
        // between otherwise-equal names.
        var tieBreak = 0
        while i < a.count, j < b.count {
            let ca = a[i]
            let cb = b[j]
            if isDigit(ca), isDigit(cb) {
                var zerosA = i
                while zerosA < a.count, a[zerosA] == 0x30 { zerosA += 1 }
                var zerosB = j
                while zerosB < b.count, b[zerosB] == 0x30 { zerosB += 1 }
                var endA = zerosA
                while endA < a.count, isDigit(a[endA]) { endA += 1 }
                var endB = zerosB
                while endB < b.count, isDigit(b[endB]) { endB += 1 }
                let lengthA = endA - zerosA
                let lengthB = endB - zerosB
                if lengthA != lengthB { return lengthA < lengthB ? -1 : 1 }
                for offset in 0..<lengthA where a[zerosA + offset] != b[zerosB + offset] {
                    return a[zerosA + offset] < b[zerosB + offset] ? -1 : 1
                }
                let leadingA = zerosA - i
                let leadingB = zerosB - j
                if tieBreak == 0, leadingA != leadingB {
                    tieBreak = leadingA < leadingB ? -1 : 1
                }
                i = endA
                j = endB
                continue
            }
            let foldedA = folded(ca)
            let foldedB = folded(cb)
            if foldedA != foldedB { return foldedA < foldedB ? -1 : 1 }
            if tieBreak == 0, ca != cb {
                tieBreak = ca < cb ? -1 : 1
            }
            i += 1
            j += 1
        }
        if i < a.count { return 1 }
        if j < b.count { return -1 }
        return tieBreak
    }

    @inline(__always)
    private nonisolated static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// ASCII lowercase; other bytes (including UTF-8 sequences) unchanged.
    @inline(__always)
    private nonisolated static func folded(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }
}
