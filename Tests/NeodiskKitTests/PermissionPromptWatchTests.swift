import Foundation
import Testing
@testable import NeodiskKit

/// A read held in a protected folder (as a macOS permission prompt holds it) is reported, then cleared.
@Suite(.serialized) struct PermissionPromptWatchTests {
    @Test func testStalledProtectedFolderIsReportedThenCleared() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = try await scanEvents(home: home, slowFolder: "Documents")

        let documents = home.appending(path: "Documents").path
        #expect(events == [documents, nil])
    }

    @Test func testSlowUnprotectedFolderIsNotReported() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try await scanEvents(home: home, slowFolder: "Projects").isEmpty)
    }

    @Test func testWatchesOnlyScansThatReachAProtectedFolder() {
        let config = PermissionPromptWatch.Configuration(home: "/Users/me")
        let ignore: @Sendable (String?) -> Void = { _ in }
        #expect(PermissionPromptWatch(scanRoot: "/", configuration: config, report: ignore) != nil)
        #expect(PermissionPromptWatch(scanRoot: "/Users", configuration: config, report: ignore) != nil)
        #expect(PermissionPromptWatch(scanRoot: "/Users/me/Documents/Taxes", configuration: config, report: ignore) != nil)
        #expect(PermissionPromptWatch(scanRoot: "/Applications", configuration: config, report: ignore) == nil)
        #expect(PermissionPromptWatch(scanRoot: "/Users/me/Projects", configuration: config, report: ignore) == nil)
        #expect(PermissionPromptWatch(scanRoot: "/Users/me", configuration: nil, report: ignore) == nil)

        let watch = PermissionPromptWatch(scanRoot: "/Users/me", configuration: config, report: ignore)
        #expect(watch?.begin("/Users/me/Projects/app") == nil)
        #expect(watch?.begin("/Users/me/DocumentsOld") == nil)
        #expect(watch?.begin("/Users/me/Library/Containers/com.example.app/Data") != nil)
        watch?.stop()
    }

    /// Scans `home` with `slowFolder`'s listing held for a second; returns the permission reports in order.
    private func scanEvents(home: URL, slowFolder: String) async throws -> [String?] {
        let engine = ScanEngine(
            enumeratedDirectoryContents: { url, _, _, _ in
                if url.lastPathComponent == slowFolder { Thread.sleep(forTimeInterval: 1) }
                // Children keep the parent's spelling, as the real reader's do (no /private/var rewrite).
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return ScanEngine.DirectoryEnumerationResult(urls: names.map { url.appending(path: $0) })
            },
            permissionPrompts: .init(home: home.path, threshold: .milliseconds(200))
        )
        var reports: [String?] = []
        var finished = false
        for try await event in engine.scan(target: ScanTarget(url: home), options: ScanOptions()) {
            switch event {
            case .waitingForPermission(let path):
                #expect(!finished)
                reports.append(path)
            case .finished:
                finished = true
            case .progress, .warning, .partial:
                break
            }
        }
        #expect(finished)
        return reports
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "NeodiskHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in ["Documents", "Projects"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: home.appending(path: "\(folder)/file.bin"))
        }
        return ScanTarget(url: home).url
    }
}
