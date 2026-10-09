import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Help ▸ Export Diagnostics writes one zip holding the system summary and
/// whatever logs exist, replacing an older export at the same path.
@MainActor
@Suite struct DiagnosticsExportTests {
    @Test func exportWritesAZipWithTheSystemSummary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Diagnostics.zip")
        try Data("stale".utf8).write(to: destination)

        try DiagnosticsExport.export(to: destination)

        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-l", destination.path]
        let output = Pipe()
        unzip.standardOutput = output
        try unzip.run()
        unzip.waitUntilExit()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(unzip.terminationStatus == 0)
        #expect(listing.contains("Diagnostics/system.txt"))
    }
}
