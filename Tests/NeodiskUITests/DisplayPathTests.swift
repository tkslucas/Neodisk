import Testing
@testable import NeodiskUI

@Suite struct DisplayPathTests {
    @Test func testFilesystemPathsPassThrough() {
        #expect(DisplayFormatters.displayPath("/Users/demo/Documents") == "/Users/demo/Documents")
        #expect(DisplayFormatters.displayPath("relative/path") == "relative/path")
    }

    @Test func testCloudPathsDropProviderAndAccount() {
        #expect(
            DisplayFormatters.displayPath("cloudscan://google/12345/My Drive/Photos/a.jpg")
                == "/My Drive/Photos/a.jpg"
        )
        // The account root itself reads as the drive root.
        #expect(DisplayFormatters.displayPath("cloudscan://google/12345") == "/")
        #expect(DisplayFormatters.displayPath("cloudscan://google/12345/top.txt") == "/top.txt")
    }
}
