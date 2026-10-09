import Foundation
import Testing
@testable import NeodiskKit

@Suite(.serialized) struct DiagnosticLogTests {
    @Test func persistsInfoAndAboveAndRotatesAtTheLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        DiagnosticLog.persist(to: directory, name: "test", maxBytes: 400)
        let log = DiagnosticLog("test")

        log.debug("never in the file")
        for index in 0..<10 {
            log.error("line \(index) padded to make the file roll over quickly")
        }

        let files = DiagnosticLog.files
        #expect(files.map(\.lastPathComponent) == ["test.log.1", "test.log"])
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!text.contains("never in the file"))
        #expect(text.contains("error [test] line 9"))
        let sizes = try files.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
        #expect(sizes.allSatisfy { $0 <= 400 + 120 })
    }

    @Test func readsTheProcessFootprint() throws {
        let reading = try #require(MemoryFootprint.read())
        #expect(reading.current > 0)
        #expect(reading.peak >= reading.current)
    }
}
