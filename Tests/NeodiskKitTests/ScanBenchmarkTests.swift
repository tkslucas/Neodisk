import Testing
import Foundation
@testable import NeodiskKit

// Opt-in (`NEODISK_BENCH=1`); prints greppable `NEODISK_BENCH result|best` lines. Quote release numbers:
// debug inflates scan phases 1.5-2.2x (`swift test -c release --filter ScanBenchmarkTests`).
@Suite(.serialized)
struct ScanBenchmarkTests {
    // MARK: - Real-world path

    /// Needs `NEODISK_BENCH_PATH` too, since there is no sensible default target.
    @Test(.enabled(if: ScanBenchmarkEnvironment.realWorldEnabled))
    func realWorldScanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let benchmarkPath = environment["NEODISK_BENCH_PATH"] else { return }
        let targetURL = URL(filePath: benchmarkPath, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            print("NEODISK_BENCH skip name=real-world reason=missing-path path=\(targetURL.path)")
            return
        }

        var options = ScanOptions()
        options.includeHiddenFiles = environment["NEODISK_BENCH_INCLUDE_HIDDEN"] == "1"
        options.tuning = ScanBenchmarkEnvironment.workerTuning()

        try await runScanBenchmark(
            name: "real-world",
            target: ScanTarget(url: targetURL),
            options: options
        )
    }

    // MARK: - Synthetic fixtures

    /// Stresses single-directory enumeration. Size via `NEODISK_BENCH_FILES` (default 2,000).
    @Test(.enabled(if: ScanBenchmarkEnvironment.benchmarksEnabled))
    func wideDirectoryScanBenchmark() async throws {
        let fileCount = ScanBenchmarkEnvironment.int("NEODISK_BENCH_FILES", default: 2_000, minimum: 1)
        let rootURL = try makeWideFixture(fileCount: fileCount)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var options = ScanOptions()
        options.tuning = ScanBenchmarkEnvironment.workerTuning()

        try await runScanBenchmark(
            name: "wide-directory",
            target: ScanTarget(url: rootURL),
            options: options
        )
    }

    /// Stresses depth, not fan-out. Depth via `NEODISK_BENCH_DEPTH` (default 64, clamped to 512).
    @Test(.enabled(if: ScanBenchmarkEnvironment.benchmarksEnabled))
    func deepDirectoryScanBenchmark() async throws {
        let depth = ScanBenchmarkEnvironment.int(
            "NEODISK_BENCH_DEPTH", default: 64, minimum: 1, maximum: 512
        )
        let rootURL = try makeDeepFixture(depth: depth)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var options = ScanOptions()
        options.tuning = ScanBenchmarkEnvironment.workerTuning()

        try await runScanBenchmark(
            name: "deep-directory",
            target: ScanTarget(url: rootURL),
            options: options
        )
    }

    /// `NEODISK_BENCH_DIRS` dirs (default 16) × `NEODISK_BENCH_FILES_PER_DIR` files (default 200).
    @Test(.enabled(if: ScanBenchmarkEnvironment.benchmarksEnabled))
    func fanoutDirectoryScanBenchmark() async throws {
        let directoryCount = ScanBenchmarkEnvironment.int("NEODISK_BENCH_DIRS", default: 16, minimum: 1)
        let filesPerDirectory = ScanBenchmarkEnvironment.int(
            "NEODISK_BENCH_FILES_PER_DIR", default: 200, minimum: 1
        )
        let rootURL = try makeFanoutFixture(
            directoryCount: directoryCount,
            filesPerDirectory: filesPerDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var options = ScanOptions()
        options.tuning = ScanBenchmarkEnvironment.workerTuning()

        try await runScanBenchmark(
            name: "fanout-directory",
            target: ScanTarget(url: rootURL),
            options: options
        )
    }

    // MARK: - Benchmark runner

    /// Runs `NEODISK_BENCH_ITERATIONS` (default 1) timed scans of `target`,
    /// prints one `result` line per iteration and one `best` summary line.
    private func runScanBenchmark(
        name: String,
        target: ScanTarget,
        options: ScanOptions
    ) async throws {
        let iterations = ScanBenchmarkEnvironment.int(
            "NEODISK_BENCH_ITERATIONS", default: 1, minimum: 1
        )
        let tuning = options.tuning

        var bestElapsed = Double.greatestFiniteMagnitude
        var bestSnapshot: ScanSnapshot?

        for iteration in 1...iterations {
            let engine = ScanEngine()
            let startedAt = ContinuousClock.now
            let snapshot = try await finishedSnapshot(target: target, options: options, engine: engine)
            let elapsed = ScanBenchmarkEnvironment.elapsedSeconds(since: startedAt)
            let stats = snapshot.aggregateStats

            print(
                "NEODISK_BENCH result name=\(name) iteration=\(iteration)"
                    + " elapsed=\(ScanBenchmarkEnvironment.format(elapsed))"
                    + " files=\(stats.fileCount) folders=\(stats.directoryCount)"
                    + " bytes=\(stats.totalAllocatedSize)"
            )

            if elapsed < bestElapsed {
                bestElapsed = elapsed
                bestSnapshot = snapshot
            }
        }

        let best = try #require(bestSnapshot)
        let bestStats = best.aggregateStats
        print(
            "NEODISK_BENCH best name=\(name)"
                + " elapsed=\(ScanBenchmarkEnvironment.format(bestElapsed))"
                + " files=\(bestStats.fileCount) folders=\(bestStats.directoryCount)"
                + " bytes=\(bestStats.totalAllocatedSize) iterations=\(iterations)"
                + " traversal_workers=\(ScanBenchmarkEnvironment.describe(tuning.directoryTraversalWorkerLimit))"
                + " classification_workers=\(ScanBenchmarkEnvironment.describe(tuning.directoryClassificationWorkerLimit))"
                + " summary_workers=\(ScanBenchmarkEnvironment.describe(tuning.atomicSummaryWorkerLimit))"
        )
    }

    // MARK: - Fixtures

    private func makeWideFixture(fileCount: Int) throws -> URL {
        let rootURL = try makeBenchmarkRoot(prefix: "neodisk-bench-wide")
        let payload = Data(repeating: 0x41, count: 64)
        for index in 0..<fileCount {
            try payload.write(to: rootURL.appending(path: String(format: "file-%08d.dat", index)))
        }
        return rootURL
    }

    private func makeDeepFixture(depth: Int) throws -> URL {
        let rootURL = try makeBenchmarkRoot(prefix: "neodisk-bench-deep")
        let payload = Data(repeating: 0x41, count: 64)
        var directoryURL = rootURL
        for index in 0..<depth {
            directoryURL.append(path: "level", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try payload.write(to: directoryURL.appending(path: String(format: "f-%03d.dat", index)))
        }
        return rootURL
    }

    private func makeFanoutFixture(directoryCount: Int, filesPerDirectory: Int) throws -> URL {
        let rootURL = try makeBenchmarkRoot(prefix: "neodisk-bench-fanout")
        let payload = Data(repeating: 0x41, count: 64)
        for directoryIndex in 0..<directoryCount {
            let directoryURL = rootURL.appending(
                path: String(format: "group-%04d", directoryIndex), directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerDirectory {
                try payload.write(to: directoryURL.appending(path: String(format: "file-%08d.dat", fileIndex)))
            }
        }
        return rootURL
    }

    private func makeBenchmarkRoot(prefix: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

// MARK: - Environment helpers

private enum ScanBenchmarkEnvironment {
    static var benchmarksEnabled: Bool {
        ProcessInfo.processInfo.environment["NEODISK_BENCH"] == "1"
    }

    static var realWorldEnabled: Bool {
        benchmarksEnabled && ProcessInfo.processInfo.environment["NEODISK_BENCH_PATH"] != nil
    }

    /// Each knob stays nil (the hardware-aware default) unless its variable is a positive integer.
    static func workerTuning() -> ScanOptions.Tuning {
        ScanOptions.Tuning(
            atomicSummaryWorkerLimit: optionalInt("NEODISK_BENCH_SUMMARY_WORKERS"),
            directoryClassificationWorkerLimit: optionalInt("NEODISK_BENCH_CLASSIFICATION_WORKERS"),
            directoryTraversalWorkerLimit: optionalInt("NEODISK_BENCH_TRAVERSAL_WORKERS")
        )
    }

    static func int(_ name: String, default defaultValue: Int, minimum: Int, maximum: Int = .max) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name], let parsed = Int(raw) else {
            return defaultValue
        }
        return Swift.min(Swift.max(parsed, minimum), maximum)
    }

    static func optionalInt(_ name: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[name], let parsed = Int(raw), parsed > 0 else {
            return nil
        }
        return parsed
    }

    static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    static func describe(_ limit: Int?) -> String {
        limit.map(String.init) ?? "default"
    }
}

private func finishedSnapshot(
    target: ScanTarget,
    options: ScanOptions,
    engine: ScanEngine
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }
    Issue.record("Expected scan to produce a final snapshot")
    throw CancellationError()
}
