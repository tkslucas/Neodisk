// swift-tools-version: 6.0

// WebAssembly build of the app's own treemap and sunburst cores for the
// personal-website demo (see README.md in this folder). A separate package
// so the app's Package.swift stays untouched: Sources/TreemapKit and
// Sources/SunburstCore are symlinks to the real app targets, and
// NeodiskWebEngine is a thin C-ABI glue layer over them.
//
// Build with ./build.sh (Embedded Swift, wasm32).

import PackageDescription

let package = Package(
    name: "NeodiskWebDemo",
    targets: [
        .target(
            name: "TreemapKit",
            path: "Sources/TreemapKit",
            swiftSettings: [.unsafeFlags(["-Osize", "-wmo"])]
        ),
        .target(
            name: "SunburstCore",
            path: "Sources/SunburstCore",
            swiftSettings: [.unsafeFlags(["-Osize", "-wmo"])]
        ),
        .executableTarget(
            name: "NeodiskWebEngine",
            dependencies: ["TreemapKit", "SunburstCore"],
            path: "Sources/NeodiskWebEngine",
            swiftSettings: [.unsafeFlags(["-Osize", "-wmo"])],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "--no-entry",
                    "-Xlinker", "--export-if-defined=__main_argc_argv",
                    "-Xlinker", "--strip-debug",
                    "-Xlinker", "--initial-memory=33554432",
                ])
            ]
        ),
    ]
)
