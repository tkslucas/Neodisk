//
//  TokenCounter.swift
//  Neodisk
//

import Foundation

/// Counts LLM tokens in a UTF-8 buffer. Swap the implementation to change
/// the metric everywhere.
public protocol TokenCounter: Sendable {
    func countTokens(in bytes: UnsafeRawBufferPointer) -> Int
}

extension TokenCounter {
    public func countTokens(in text: String) -> Int {
        var text = text
        return text.withUTF8 { countTokens(in: UnsafeRawBufferPointer($0)) }
    }
}

/// Fast single-pass estimate of BPE token counts. Fitted against the
/// cl100k/o200k tokenizers on prose, Markdown and code: about 4% mean error.
public struct HeuristicTokenCounter: TokenCounter {
    public init() {}

    private enum ByteClass: UInt8 {
        case lower, upper, digit, space, newline, punct, continuation, wide, emoji
    }

    private static let classes: [ByteClass] = (0...255).map { byte in
        switch byte {
        case 0x61...0x7A: return .lower
        case 0x41...0x5A: return .upper
        case 0x30...0x39: return .digit
        case 0x20, 0x09: return .space
        case 0x0A, 0x0D: return .newline
        case 0x00..<0x80: return .punct
        case 0x80..<0xC0: return .continuation
        // Two-byte scalars (accented Latin, Greek, Cyrillic) read as letters.
        case 0xC0..<0xE0: return .lower
        case 0xE0..<0xF0: return .wide
        default: return .emoji
        }
    }

    public func countTokens(in bytes: UnsafeRawBufferPointer) -> Int {
        var words = 0, punctRuns = 0, digitGroups = 0, spaceRuns = 0, lineBreaks = 0, wide = 0
        var previous = ByteClass.newline
        var run = 0
        Self.classes.withUnsafeBufferPointer { classes in
            for byte in bytes {
                let current = classes[Int(byte)]
                switch current {
                case .continuation:
                    continue
                case .lower:
                    if previous != .lower && previous != .upper { words += 1 }
                case .upper:
                    // camelCase humps split into separate tokens.
                    if previous != .upper { words += 1 }
                case .digit:
                    if previous != .digit { run = 0 }
                    if run % 3 == 0 { digitGroups += 1 }
                    run += 1
                case .space:
                    run = previous == .space ? run + 1 : 1
                    if run == 2 { spaceRuns += 1 }
                case .newline:
                    if previous != .newline { lineBreaks += 1 }
                case .punct:
                    if previous != .punct { punctRuns += 1 }
                case .wide:
                    wide += 1
                case .emoji:
                    wide += 2
                }
                previous = current
            }
        }
        let estimate = 0.97 * Double(words) + 0.9 * Double(punctRuns) + 1.47 * Double(digitGroups)
            + 0.15 * Double(spaceRuns) + 1.16 * Double(lineBreaks) + 1.39 * Double(wide)
        return Int(estimate.rounded())
    }
}
