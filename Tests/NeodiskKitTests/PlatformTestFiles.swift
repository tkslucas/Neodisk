import Foundation
#if os(Windows)
import WinSDK
#endif

/// Hides a test item the platform's way: a dot name already hides it on Apple platforms and Linux, while
/// Windows goes by the hidden attribute.
func markHiddenOnWindows(_ url: URL) {
    #if os(Windows)
    _ = url.path.withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_HIDDEN)) }
    #endif
}
