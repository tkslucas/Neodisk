// swift-tools-version: 6.0

import PackageDescription

// One repository, one UI-free Swift core, one native app per platform.
//
// The core — scan engine and tree model (NeodiskKit), treemap geometry and
// rasterizer (TreemapKit), sunburst geometry (SunburstCore), cloud-drive
// scanning (CloudScanKit), and the `diskscan` CLI — builds on every
// platform. Each platform's app is a thin native shell over it, written
// against that platform's own toolkit:
//
//   macOS   NeodiskUI + Neodisk   SwiftUI / AppKit (+ Sparkle)
//
// Platform differences below the UI (directory enumeration, change history,
// compression, hashing, credential storage) live behind `#if os(...)` in the
// core, never in the shells.

#if os(macOS)
// The Command Line Tools keep lib_TestingInterop.dylib off the default
// search path; harmless on full Xcode toolchains.
let testingInteropLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
        "-Xlinker", "-rpath",
        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
    ])
]
#else
let testingInteropLinkerSettings: [LinkerSetting] = []
#endif

/// Apple platforms get CryptoKit from the SDK; everywhere else the API-
/// identical `Crypto` module from swift-crypto stands in.
let nonApplePlatforms: [Platform] = [.linux, .windows, .android, .openbsd]

/// The Command Line Tools toolchain ships without XCTest or Swift Testing, so
/// macOS tests depend on swift-testing explicitly. Other toolchains bundle
/// Swift Testing; building the package copy there would shadow it.
let testingDependency: Target.Dependency = .product(
    name: "Testing",
    package: "swift-testing",
    condition: .when(platforms: [.macOS])
)

var products: [Product] = [
    .library(name: "NeodiskKit", targets: ["NeodiskKit"]),
    .library(name: "TreemapKit", targets: ["TreemapKit"]),
    .library(name: "SunburstCore", targets: ["SunburstCore"]),
    .executable(name: "diskscan", targets: ["NeodiskCLI"]),
]

// Every dependency is declared on every platform — only its use is
// conditional — so all platforms resolve the same graph and share one
// Package.resolved.
let dependencies: [Package.Dependency] = [
    // Lets `swift test` work on the macOS Command Line Tools (no Xcode).
    .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.3.0"),
    // Sparkle powers auto-updates for the packaged macOS .app (GitHub
    // releases appcast). Ships as a prebuilt xcframework, so it works on the
    // Command Line Tools toolchain. See Packaging/SPARKLE.md.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    // CryptoKit's API off Apple platforms (SHA-256 for duplicate hashing,
    // snapshot keys, PKCE).
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]

var targets: [Target] = [
    // UI-free scanning core: models + services. Foundation + the platform
    // libc only — no AppKit, no SwiftUI, no GTK. Per-platform fast paths
    // (getattrlistbulk + FSEvents on macOS, getdents64 + statx on Linux) sit
    // behind the same internal interfaces. Includes third-party code (MIT),
    // attributed in LICENSE.
    .target(
        name: "NeodiskKit",
        dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApplePlatforms)),
            .target(name: "CZstd", condition: .when(platforms: [.linux])),
        ],
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
    // Pure sunburst layout, branch-hue coloring, hit-testing, and zoom
    // remap math. Foundation-only, zero dependencies (SIMD3 comes from
    // the stdlib) — the rendering stays in each platform's app, so this core
    // is consumable anywhere (including a WebAssembly demo).
    .target(
        name: "SunburstCore",
        path: "Sources/SunburstCore"
    ),
    // Remote cloud-drive scanning (CloudScan): provider protocol, tree
    // assembly, and the scan service that emits the same event stream as
    // ScanEngine. UI-free like NeodiskKit. Deliberately excludable: drop
    // "CloudScanKit" from NeodiskUI's dependencies below and the app
    // builds without the feature (the UI glue is #if canImport-guarded).
    .target(
        name: "CloudScanKit",
        dependencies: [
            "NeodiskKit",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApplePlatforms)),
        ],
        path: "Sources/CloudScanKit"
    ),
    // Linux's snapshot payload codec (Apple platforms use LZFSE from the
    // Compression framework instead).
    .systemLibrary(
        name: "CZstd",
        path: "Sources/CZstd",
        pkgConfig: "libzstd",
        providers: [
            .apt(["libzstd-dev"]),
            .yum(["libzstd-devel"]),
        ]
    ),
    .testTarget(
        name: "NeodiskKitTests",
        dependencies: ["NeodiskKit", testingDependency],
        path: "Tests/NeodiskKitTests",
        linkerSettings: testingInteropLinkerSettings
    ),
    .testTarget(
        name: "TreemapKitTests",
        dependencies: ["TreemapKit", testingDependency],
        path: "Tests/TreemapKitTests",
        resources: [
            // Golden PNG for the cushion render regression test.
            .copy("Fixtures")
        ],
        linkerSettings: testingInteropLinkerSettings
    ),
    .testTarget(
        name: "CloudScanKitTests",
        dependencies: ["CloudScanKit", "NeodiskKit", testingDependency],
        path: "Tests/CloudScanKitTests",
        linkerSettings: testingInteropLinkerSettings
    ),
]

#if os(macOS)
products.append(.executable(name: "Neodisk", targets: ["Neodisk"]))
targets += [
    // The macOS app: SwiftUI/AppKit views, view model, scan lifecycle glue.
    .target(
        name: "NeodiskUI",
        dependencies: [
            "NeodiskKit",
            "TreemapKit",
            "SunburstCore",
            "CloudScanKit",
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
        name: "NeodiskUITests",
        dependencies: [
            "NeodiskUI",
            "NeodiskKit",
            "TreemapKit",
            testingDependency
        ],
        path: "Tests/NeodiskUITests",
        linkerSettings: testingInteropLinkerSettings
    ),
]
#endif

let package = Package(
    name: "Neodisk",
    platforms: [
        .macOS("14.0")
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
