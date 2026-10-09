import Foundation
import Testing
@testable import NeodiskKit

@Suite struct AppChannelTests {
    @Test func channelsNeverShareAnIdentityOrStorage() {
        let stable = AppChannel.stable, nightly = AppChannel.nightly
        #expect(stable.identifier == "com.lucastakayasu.Neodisk")
        #expect(stable.appName == "Neodisk")
        #expect(stable.slug == "neodisk")
        #expect(nightly.identifier != stable.identifier)
        #expect(nightly.appName != stable.appName)
        #expect(nightly.slug != stable.slug)
    }

    @Test func snapshotCacheLivesUnderTheChannelsFolder() {
        guard ProcessInfo.processInfo.environment["NEODISK_SNAPSHOT_DIR"] == nil else { return }
        let path = ScanSnapshotCache.defaultDirectoryURL.path(percentEncoded: false)
        #expect(path.hasSuffix("/\(AppChannel.current.appName)/ScanCache/"))
    }
}
