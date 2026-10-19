import Foundation
import Testing
@testable import NeodiskKit

@Suite struct FirmlinkPathTranslatorTests {
    private let dataMount = FirmlinkPathTranslator.dataVolumeMountPoint

    private func makeTranslator() -> FirmlinkPathTranslator {
        FirmlinkPathTranslator(table: [
            "/Applications": "Applications",
            "/Users": "Users",
            "/private": "private"
        ])
    }

    // MARK: forward (event relative path -> firmlinked absolute)

    @Test func dataRelativePathMapsToFirmlinkedAbsolute() {
        let translator = makeTranslator()
        #expect(translator.absolutePath(forEventRelativePath: "Users/lucas", mountPoint: dataMount, targetPath: "/") == "/Users/lucas")
        #expect(translator.absolutePath(forEventRelativePath: "Applications/Foo.app", mountPoint: dataMount, targetPath: "/") == "/Applications/Foo.app")
    }

    @Test func firmlinkRootItselfMaps() {
        let translator = makeTranslator()
        #expect(translator.absolutePath(forEventRelativePath: "Users", mountPoint: dataMount, targetPath: "/") == "/Users")
    }

    @Test func nonFirmlinkRelativeFallsBackToMountPoint() {
        let translator = makeTranslator()
        #expect(translator.absolutePath(forEventRelativePath: "SomeData/file.bin", mountPoint: dataMount, targetPath: "/") == "\(dataMount)/SomeData/file.bin")
    }

    @Test func firmlinkTableIgnoredOffTheDataVolume() {
        let translator = makeTranslator()
        // A plain external volume may coincidentally have a top-level "Users";
        // it must not be firmlink-rewritten into the root namespace.
        #expect(translator.absolutePath(forEventRelativePath: "Users/x", mountPoint: "/Volumes/Ext", targetPath: "/Volumes/Ext") == "/Volumes/Ext/Users/x")
        #expect(translator.absolutePath(forEventRelativePath: "Movies/a.mov", mountPoint: "/Volumes/Ext", targetPath: "/Volumes/Ext") == "/Volumes/Ext/Movies/a.mov")
    }

    @Test func emptyRelativeIsTheVolumeRoot() {
        let translator = makeTranslator()
        #expect(translator.absolutePath(forEventRelativePath: "", mountPoint: "/Volumes/Ext", targetPath: "/Volumes/Ext") == "/Volumes/Ext")
        #expect(translator.absolutePath(forEventRelativePath: "", mountPoint: dataMount, targetPath: "/") == dataMount)
    }

    // MARK: reverse (target absolute path -> volume-relative watch path)

    @Test func firmlinkedTargetMapsToDataRelative() {
        let translator = makeTranslator()
        #expect(translator.relativePath(forTarget: "/Users/lucas", mountPoint: dataMount) == "Users/lucas")
        #expect(translator.relativePath(forTarget: "/Users", mountPoint: dataMount) == "Users")
        #expect(translator.relativePath(forTarget: "/private/var/folders/x", mountPoint: dataMount) == "private/var/folders/x")
    }

    @Test func plainVolumeTargetStripsMountPoint() {
        let translator = makeTranslator()
        #expect(translator.relativePath(forTarget: "/Volumes/Ext/Movies/a.mov", mountPoint: "/Volumes/Ext") == "Movies/a.mov")
    }

    @Test func targetAtVolumeRootMapsToEmpty() {
        let translator = makeTranslator()
        #expect(translator.relativePath(forTarget: "/Volumes/Ext", mountPoint: "/Volumes/Ext") == "")
    }

    @Test func rootTargetMapsToEmpty() {
        let translator = makeTranslator()
        // A "/" scan watches the Data volume root; the reverse of the Data
        // mount point is the empty relative path.
        #expect(translator.relativePath(forTarget: "/", mountPoint: dataMount) == "")
    }

    // MARK: /private standardization (Foundation strips it for var/tmp/etc)

    @Test func privateVarEventsSurfaceInTheStrippedFormForStrippedTargets() {
        // The target keeps the stripped /var form while the journal speaks /private; without bridging both ways
        // every event lands "outside target".
        let translator = makeTranslator()
        #expect(
            translator.relativePath(forTarget: "/var/folders/x", mountPoint: dataMount)
                == "private/var/folders/x"
        )
        #expect(
            translator.absolutePath(forEventRelativePath: "private/var/folders/x/f.bin", mountPoint: dataMount, targetPath: "/var/folders/x")
                == "/var/folders/x/f.bin"
        )
        // Non-special /private children keep their prefix.
        #expect(
            translator.absolutePath(forEventRelativePath: "private/other", mountPoint: dataMount, targetPath: "/var/folders/x")
                == "/private/other"
        )
    }

    @Test func privateVarEventsStayQualifiedForRootTargets() {
        // A "/" scan stores /private/var/..., so stripping made events miss the baseline and force a full scan.
        let translator = makeTranslator()
        #expect(
            translator.absolutePath(forEventRelativePath: "private/var/folders/x/f.bin", mountPoint: dataMount, targetPath: "/")
                == "/private/var/folders/x/f.bin"
        )
        #expect(
            translator.absolutePath(forEventRelativePath: "private/tmp/t", mountPoint: dataMount, targetPath: "/")
                == "/private/tmp/t"
        )
        // Same for a target that is itself inside the qualified namespace.
        #expect(
            translator.absolutePath(forEventRelativePath: "private/var/log/l", mountPoint: dataMount, targetPath: "/private")
                == "/private/var/log/l"
        )
    }

    @Test func privatePrefixHelpersRoundTrip() {
        #expect(FirmlinkPathTranslator.standardizedPrivatePrefix("/private/var/x") == "/var/x")
        #expect(FirmlinkPathTranslator.standardizedPrivatePrefix("/private/tmp") == "/tmp")
        #expect(FirmlinkPathTranslator.standardizedPrivatePrefix("/private/etc/hosts") == "/etc/hosts")
        #expect(FirmlinkPathTranslator.standardizedPrivatePrefix("/private/varx") == "/private/varx")
        #expect(FirmlinkPathTranslator.standardizedPrivatePrefix("/Users/x") == "/Users/x")
        #expect(FirmlinkPathTranslator.privateQualified("/var/x") == "/private/var/x")
        #expect(FirmlinkPathTranslator.privateQualified("/tmp") == "/private/tmp")
        #expect(FirmlinkPathTranslator.privateQualified("/varx") == "/varx")
        #expect(FirmlinkPathTranslator.privateQualified("/Users/x") == "/Users/x")
    }

    // MARK: longest-prefix precedence (nested firmlinks)

    @Test func longestFirmlinkPrefixWins() {
        let translator = FirmlinkPathTranslator(table: ["/a": "a", "/a/b": "nested"])
        // reverse: the longer firmlink must win over the shorter prefix.
        #expect(translator.relativePath(forTarget: "/a/b/c", mountPoint: dataMount) == "nested/c")
        #expect(translator.relativePath(forTarget: "/a/x", mountPoint: dataMount) == "a/x")
        // forward: the same, mirrored.
        #expect(translator.absolutePath(forEventRelativePath: "nested/c", mountPoint: dataMount, targetPath: "/") == "/a/b/c")
        #expect(translator.absolutePath(forEventRelativePath: "a/x", mountPoint: dataMount, targetPath: "/") == "/a/x")
    }
}
