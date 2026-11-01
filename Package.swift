// swift-tools-version: 6.0

import PackageDescription

// One repository, one UI-free Swift core, one native app per platform.
//
// The core — scan engine and tree model (NeodiskKit), treemap geometry and
// rasterizer (TreemapKit), sunburst geometry (SunburstCore), the
// platform-neutral app vocabulary every shell
// shares (NeodiskAppModel), and the `diskscan` CLI — builds on every
// platform. Each platform's app is a thin native shell over it, written
// against that platform's own toolkit:
//
//   macOS   NeodiskUI + Neodisk   SwiftUI / AppKit (+ Sparkle)
//   Linux   NeodiskGTK            GTK 4 + libadwaita through Swift's C interop
//
// Platform differences below the UI (directory enumeration, change history,
// compression, hashing) live behind `#if os(...)` in the
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
    // snapshot keys).
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
            .target(name: "CLinuxDirent", condition: .when(platforms: [.linux])),
        ],
        path: "Sources/NeodiskKit",
        linkerSettings: [
            // The Compression API behind Windows snapshot payloads (compressapi.h).
            .linkedLibrary("Cabinet", .when(platforms: [.windows])),
        ]
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
    // The app layer every platform's shell shares: file-kind classification
    // and catalogs, visualization palettes (as sRGB triples, not toolkit
    // colors), age buckets, the treemap scene (layout, cells, labels,
    // hit-testing), keyboard navigation, whole-scan search, and display
    // formatting. No AppKit, SwiftUI, or GTK; declarations are `package`
    // access, visible to the shells without becoming public API.
    .target(
        name: "NeodiskAppModel",
        dependencies: ["NeodiskKit", "TreemapKit", "SunburstCore"],
        path: "Sources/NeodiskAppModel"
    ),
    // getdents64 for the Linux directory reader; header only.
    .systemLibrary(name: "CLinuxDirent", path: "Sources/CLinuxDirent"),
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
        name: "NeodiskAppModelTests",
        dependencies: ["NeodiskAppModel", "NeodiskKit", "TreemapKit", "SunburstCore", testingDependency],
        path: "Tests/NeodiskAppModelTests",
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
            "NeodiskAppModel",
            "TreemapKit",
            "SunburstCore",
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
            "NeodiskAppModel",
            "NeodiskKit",
            "TreemapKit",
            testingDependency
        ],
        path: "Tests/NeodiskUITests",
        linkerSettings: testingInteropLinkerSettings
    ),
]
#endif

#if os(Linux)
products.append(.executable(name: "neodisk", targets: ["NeodiskGTK"]))
targets += [
    // GTK 4 and libadwaita, imported straight from their C headers. GTK 4.14
    // and libadwaita 1.5 (Ubuntu 24.04 LTS) are the floor.
    .systemLibrary(
        name: "CGtk",
        path: "Sources/CGtk",
        pkgConfig: "gtk4 libadwaita-1",
        providers: [
            .apt(["libgtk-4-dev", "libadwaita-1-dev"]),
            .yum(["gtk4-devel", "libadwaita-devel"]),
        ]
    ),
    // The Linux app: a GTK/libadwaita shell over the shared core, written
    // in Swift against GTK's C API the way the macOS app is written against
    // AppKit — native widgets, no cross-platform UI layer in between.
    .executableTarget(
        name: "NeodiskGTK",
        dependencies: ["NeodiskKit", "NeodiskAppModel", "TreemapKit", "SunburstCore", "CGtk"],
        path: "Sources/NeodiskGTK"
    ),
]
#endif

#if os(Windows)
products.append(.executable(name: "neodisk", targets: ["NeodiskWin"]))
targets += [
    // The COM-heavy half of the Windows platform layer behind a C API: Direct2D/DirectWrite drawing for the
    // window chrome, UI Automation providers for custom-drawn elements, uxtheme, the folder picker, PNG capture.
    .target(
        name: "CNeodiskWin",
        path: "Sources/CNeodiskWin",
        linkerSettings: [
            .linkedLibrary("d2d1"),
            .linkedLibrary("dwrite"),
            .linkedLibrary("windowscodecs"),
            .linkedLibrary("uxtheme"),
            .linkedLibrary("uiautomationcore"),
            .linkedLibrary("dwmapi"),
            .linkedLibrary("comctl32"),
            .linkedLibrary("ole32"),
            .linkedLibrary("oleaut32"),
            .linkedLibrary("oleacc"),
            .linkedLibrary("shell32"),
            .linkedLibrary("gdi32"),
            .linkedLibrary("user32"),
        ]
    ),
    // Direct3D 11, a flip-model swap chain, Direct2D, DirectWrite and WIC behind a C API for the treemap and
    // sunburst canvas. C++ because DirectWrite has no C interface.
    .target(
        name: "CNeodiskCanvas",
        path: "Sources/CNeodiskCanvas",
        linkerSettings: [
            .linkedLibrary("d2d1"),
            .linkedLibrary("d3d11"),
            .linkedLibrary("dxgi"),
            .linkedLibrary("dwrite"),
            .linkedLibrary("windowscodecs"),
            .linkedLibrary("dxguid"),
            .linkedLibrary("ole32"),
        ]
    ),
    // The Windows app: Swift over Win32, with real controls where they carry keyboard and Narrator support
    // (the file list, the search field) and Direct2D surfaces with UI Automation providers for the rest.
    .executableTarget(
        name: "NeodiskWin",
        dependencies: ["NeodiskKit", "NeodiskAppModel", "TreemapKit", "SunburstCore", "CNeodiskWin", "CNeodiskCanvas"],
        path: "Sources/NeodiskWin",
        exclude: ["Neodisk.manifest"],
        linkerSettings: [
            // A GUI program (no console window), with the manifest that turns on per-monitor DPI awareness,
            // long paths, and version 6 of the common controls.
            .unsafeFlags([
                "-Xlinker", "/SUBSYSTEM:WINDOWS",
                "-Xlinker", "/ENTRY:mainCRTStartup",
                "-Xlinker", "/MANIFEST:EMBED",
                "-Xlinker", "/MANIFESTINPUT:\(Context.packageDirectory)/Sources/NeodiskWin/Neodisk.manifest",
            ]),
        ]
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
