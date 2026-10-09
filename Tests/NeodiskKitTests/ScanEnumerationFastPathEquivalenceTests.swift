import Foundation
import Testing
@testable import NeodiskKit

/// Proves the enumeration hot-path string fast paths are verdict-identical to
/// the URL-based oracles they replace: `ScanExclusionMatcher.excludes(
/// normalizedParentPath:childName:isDirectory:)` vs `excludes(_:isDirectory:)`,
/// and `ScanEngine.includedChildName(_:underParentPath:behavior:)` vs
/// `includedChildURL(_:under:behavior:)`. The precondition both fast paths rely
/// on — an already-normalized parent path plus a single dot/slash-free child
/// component — is exactly what `bulkDirectoryEntries` guarantees, and the
/// generator exercises it across roots, patterns, cloud opt-in/out, unicode and
/// dot-name children, the scan root itself, and cloud-location roots.
@Suite struct ScanEnumerationFastPathEquivalenceTests {
    /// Deterministic SplitMix64 so failures reproduce from the seed.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let roots = [
        "/",
        "/Users",
        "/Users/alice",
        "/Users/alice/Projects",
        "/Users/alice/Library/CloudStorage",
        "/Users/alice/Library/Mobile Documents",
        "/Volumes/Ext",
        "/tmp/NeodiskProject",
        "/System"
    ]

    private static let patternSets: [[String]] = [
        [],
        ["node_modules/", "*.log", ".DS_Store", "build/", "DerivedData/"],
        ["Library/Caches/**"],
        ["*.tmp", "**/*.o"],
        ["node_modules/", "Library/Mobile Documents/"]
    ]

    /// Single, dot/slash-free path components (never "." or ".."), including
    /// dot-names, unicode, spaces, glob-bait, and cloud-location names.
    private static let childNames = [
        "node_modules", "file.log", ".DS_Store", "build", "DerivedData",
        ".config", "..weird", "café", "a b", "x.tmp", "y.o", "Sub",
        "Library", "CloudStorage", "Mobile Documents", "Documents",
        "alice", "artifact.o", "réséau.log", "Caches", ".hidden.tmp"
    ]

    /// Builds a normalized parent path by starting from a root and appending a
    /// few clean components — the same shape the traversal's parent URLs have.
    private func normalizedParentPath(
        root: String, depth: Int, matcher: ScanExclusionMatcher, rng: inout SeededGenerator
    ) -> String {
        var url = URL(filePath: root, directoryHint: .isDirectory)
        for _ in 0..<depth {
            let name = Self.childNames[Int(rng.next() % UInt64(Self.childNames.count))]
            url = url.appending(path: name, directoryHint: .isDirectory)
        }
        // Standardize exactly as the hot path does before handing us the parent.
        return matcher.scanPath(of: url)
    }

    @Test func fastPathsMatchURLOraclesAcrossRandomizedInputs() {
        var rng = SeededGenerator(seed: 0xEC12_3F5A_9017_44BD)
        let behaviors = [
            ScanEngine.ScanBehavior(excludesStartupVolumeInternals: false),
            ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        ]

        for root in Self.roots {
            for patterns in Self.patternSets {
                for includeCloudStorage in [false, true] {
                    let matcher = ScanExclusionMatcher(
                        patterns: patterns,
                        rootPath: root,
                        includeCloudStorage: includeCloudStorage
                    )

                    for _ in 0..<200 {
                        let depth = Int(rng.next() % 4)
                        let parentPath = normalizedParentPath(root: root, depth: depth, matcher: matcher, rng: &rng)
                        let parentURL = URL(filePath: parentPath, directoryHint: .isDirectory)
                        let childName = Self.childNames[Int(rng.next() % UInt64(Self.childNames.count))]
                        let isDirectory = rng.next() & 1 == 0
                        let childURL = parentURL.appending(
                            path: childName,
                            directoryHint: isDirectory ? .isDirectory : .notDirectory
                        )

                        let oracleExcludes = matcher.excludes(childURL, isDirectory: isDirectory)
                        let fastExcludes = matcher.excludes(
                            normalizedParentPath: parentPath,
                            childName: childName,
                            isDirectory: isDirectory
                        )
                        #expect(
                            oracleExcludes == fastExcludes,
                            "exclusion mismatch parent=\(parentPath) child=\(childName) dir=\(isDirectory) root=\(root) patterns=\(patterns) cloud=\(includeCloudStorage)"
                        )

                        for behavior in behaviors {
                            let oracleIncluded = ScanEngine.includedChildURL(
                                childURL, under: parentURL, behavior: behavior
                            )
                            let fastIncluded = ScanEngine.includedChildName(
                                childName, underParentPath: parentPath, behavior: behavior
                            )
                            #expect(
                                oracleIncluded == fastIncluded,
                                "hidden-gate mismatch parent=\(parentPath) child=\(childName) startupInternals=\(behavior.excludesStartupVolumeInternals)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// The enumeration hot path builds each child's node id by string
    /// concatenation — `childBasePath + "/" + name` (or `"/" + name` at the
    /// volume root) — and relies on it staying byte-identical to
    /// `url.appending(path: name).path`, the form the compatibility path and
    /// snapshot ids use. In production a debug `assert` guards that equality, but
    /// `-O` release builds (what ships and what benchmarks run) strip it, so the
    /// only place the invariant is checked in release is here. The subtle case is
    /// unicode normalization: `URL.appending(path:)` could in principle normalize
    /// an NFD-decomposed name (an `e` + combining accent) while concatenation
    /// preserves the raw bytes — which would silently drift the fast-path id from
    /// the compatibility/snapshot id. This asserts they agree across NFD/NFC,
    /// emoji, percent, trailing-dot and leading-dot names, at ordinary parents
    /// and at the volume root.
    @Test func nodeIDConcatenationMatchesAppendedURLPathAcrossExoticNames() {
        // Mirrors ScanEngine+Enumeration's `childPath` expression exactly.
        func concatenatedID(base childBasePath: String, name: String) -> String {
            childBasePath == "/" ? "/" + name : childBasePath + "/" + name
        }

        let exoticNames = [
            "caf\u{00E9}",              // NFC precomposed é
            "cafe\u{0301}",             // NFD: e + combining acute
            "re\u{0301}se\u{0301}au.log", // NFD, multiple combining marks
            "\u{1F600}emoji",           // emoji (astral plane)
            "weird%20name",             // literal percent sequence
            "trailing.",                // trailing dot
            "..weird",                  // leading dots (not . or ..)
            ".hidden",                  // leading dot
            "a b",                      // space
            "Ñandú",                    // NFC with tilde
            "\u{4E2D}\u{6587}",         // CJK
            "plain"
        ]
        let bases = [
            "/", "/Users", "/Users/alice", "/Volumes/Ext",
            "/Users/alice/Library/CloudStorage"
        ]

        for base in bases {
            let baseURL = URL(filePath: base, directoryHint: .isDirectory)
            for name in exoticNames {
                for isDirectory in [false, true] {
                    let appended = baseURL.appending(
                        path: name,
                        directoryHint: isDirectory ? .isDirectory : .notDirectory
                    ).path
                    let scalars = name.unicodeScalars
                        .map { String(format: "U+%04X", $0.value) }
                        .joined(separator: " ")
                    #expect(
                        concatenatedID(base: base, name: name) == appended,
                        "node-id concat diverged from appended URL path: base=\(base) name-scalars=\(scalars) dir=\(isDirectory)"
                    )
                }
            }
        }
    }

    /// The scan root itself and the concrete cloud-location roots are boundary
    /// cases in the cloud rules; assert the fast path agrees there too.
    @Test func fastPathMatchesForRootAndCloudBoundaries() {
        let cases = [
            ("/Users/alice", "/Users/alice/Library", "CloudStorage"),
            ("/Users/alice", "/Users/alice/Library", "Mobile Documents"),
            ("/", "/Users/alice/Library", "CloudStorage"),
            ("/Users", "/Users/bob/Library", "Mobile Documents"),
            ("/Users/alice/Library/CloudStorage", "/Users/alice/Library/CloudStorage", "Dropbox")
        ]

        for includeCloudStorage in [false, true] {
            for (root, parent, child) in cases {
                let matcher = ScanExclusionMatcher(
                    patterns: [],
                    rootPath: root,
                    includeCloudStorage: includeCloudStorage
                )
                let parentURL = URL(filePath: parent, directoryHint: .isDirectory)
                let parentPath = matcher.scanPath(of: parentURL)
                for isDirectory in [false, true] {
                    let childURL = parentURL.appending(
                        path: child,
                        directoryHint: isDirectory ? .isDirectory : .notDirectory
                    )
                    #expect(
                        matcher.excludes(childURL, isDirectory: isDirectory)
                            == matcher.excludes(
                                normalizedParentPath: parentPath,
                                childName: child,
                                isDirectory: isDirectory
                            )
                    )
                }
            }
        }
    }
}
