// swift-tools-version: 6.0

import PackageDescription

// The Command Line Tools keep lib_TestingInterop.dylib off the default
// search path; harmless on full Xcode toolchains.
let testingInteropLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
        "-Xlinker", "-rpath",
        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
    ])
]

let package = Package(
    name: "Neodisk",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "NeodiskKit",
            targets: ["NeodiskKit"]
        ),
        .library(
            name: "TreemapKit",
            targets: ["TreemapKit"]
        ),
        .executable(
            name: "Neodisk",
            targets: ["Neodisk"]
        ),
        .executable(
            name: "diskscan",
            targets: ["NeodiskCLI"]
        )
    ],
    dependencies: [
        // The Command Line Tools toolchain ships without XCTest or Swift
        // Testing; depending on swift-testing explicitly lets `swift test`
        // work with no Xcode installed. Full Xcode toolchains work too.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.3.0"),
        // Sparkle powers auto-updates for the packaged .app (GitHub releases
        // appcast). Ships as a prebuilt xcframework, so it works on the
        // Command Line Tools toolchain. See Packaging/SPARKLE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        // UI-free scanning core: models + services. Foundation/Darwin/
        // Dispatch (+ CryptoKit, UniformTypeIdentifiers) only — no AppKit,
        // no SwiftUI. Derived from Radix (MIT, attributed in LICENSE).
        .target(
            name: "NeodiskKit",
            path: "Sources/NeodiskKit"
        ),
        // Reference CLI consumer of the scanning core (`diskscan`).
        .executableTarget(
            name: "NeodiskCLI",
            dependencies: ["NeodiskKit"],
            path: "Sources/NeodiskCLI"
        ),
        // Pure treemap geometry (squarify, viewport, cushion rasterizer).
        // No dependency on the scanning core.
        .target(
            name: "TreemapKit",
            path: "Sources/TreemapKit"
        ),
        // The macOS app: SwiftUI/AppKit views, view model, scan lifecycle glue.
        .target(
            name: "NeodiskUI",
            dependencies: [
                "NeodiskKit",
                "TreemapKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NeodiskUI"
        ),
        .executableTarget(
            name: "Neodisk",
            dependencies: ["NeodiskUI"],
            path: "Sources/Neodisk"
        ),
        .testTarget(
            name: "NeodiskKitTests",
            dependencies: [
                "NeodiskKit",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/NeodiskKitTests",
            linkerSettings: testingInteropLinkerSettings
        ),
        .testTarget(
            name: "TreemapKitTests",
            dependencies: [
                "TreemapKit",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/TreemapKitTests",
            resources: [
                // Golden PNG for the cushion render regression test.
                .copy("Fixtures")
            ],
            linkerSettings: testingInteropLinkerSettings
        ),
        .testTarget(
            name: "NeodiskUITests",
            dependencies: [
                "NeodiskUI",
                "NeodiskKit",
                "TreemapKit",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/NeodiskUITests",
            linkerSettings: testingInteropLinkerSettings
        )
    ]
)
