//
//  HeadlessRender.swift
//  Neodisk
//
//  Debug/CI entry point: scan a folder and write the cushion treemap as a
//  PNG, no window required. Invoked as `Neodisk --render-png <path> <out>`.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TreemapKit
import NeodiskKit

public enum HeadlessRender {
    /// Handles `--render-png` if present. Returns true when the invocation
    /// was consumed (the caller should exit instead of launching the app).
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: "--render-png") else { return false }
        guard arguments.count > flagIndex + 2 else {
            FileHandle.standardError.write(Data("usage: Neodisk --render-png <scan-path> <output.png>\n".utf8))
            exit(2)
        }

        let scanPath = arguments[flagIndex + 1]
        let outputPath = arguments[flagIndex + 2]

        // Optional zoom for debugging: <scale> <fx> <fy>, where fx/fy pick
        // the viewport origin as a fraction (0...1) of its maximum.
        var zoomScale: CGFloat = 1
        var originFraction = CGPoint.zero
        if arguments.count > flagIndex + 5,
           let scale = Double(arguments[flagIndex + 3]),
           let fx = Double(arguments[flagIndex + 4]),
           let fy = Double(arguments[flagIndex + 5]) {
            zoomScale = scale
            originFraction = CGPoint(x: fx, y: fy)
        }

        let exitCode = renderPNG(
            scanPath: scanPath,
            outputPath: outputPath,
            zoomScale: zoomScale,
            originFraction: originFraction
        )
        exit(exitCode)
    }

    static func renderPNG(
        scanPath: String,
        outputPath: String,
        size: CGSize = CGSize(width: 1200, height: 800),
        zoomScale: CGFloat = 1,
        originFraction: CGPoint = .zero
    ) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Int32 = 1

        Task.detached {
            defer { semaphore.signal() }
            do {
                let target = ScanTarget(url: URL(filePath: scanPath, directoryHint: .isDirectory))
                let engine = ScanEngine()
                var snapshot: ScanSnapshot?
                for try await event in engine.scan(target: target, options: ScanOptions()) {
                    if case .finished(let finished) = event {
                        snapshot = finished
                    }
                }
                guard let snapshot else {
                    FileHandle.standardError.write(Data("scan produced no snapshot\n".utf8))
                    return
                }

                let store = snapshot.treeStore
                let environment = ProcessInfo.processInfo.environment
                // NEODISK_RENDER_PALETTE=<id> renders with that VizPalette
                // (standard, vivid, pastel, earth, colorblind); unknown ids
                // fall back to standard.
                let palette = VizPalette.named(
                    environment["NEODISK_RENDER_PALETTE"] ?? VizPalette.standard.id
                )
                let catalog = FileKindCatalog.build(from: store, palette: palette)
                // NEODISK_RENDER_COLOR_MODE=age renders the modification-age
                // heatmap; =branch the sunburst-matching branch hues (flat
                // style's Largest/panel-hidden coloring); default kind colors.
                let colorMode: TreemapColorMode = switch environment["NEODISK_RENDER_COLOR_MODE"] {
                case "age": .age(referenceDate: snapshot.finishedAt ?? snapshot.startedAt)
                case "branch": .branch
                default: .kind
                }
                // NEODISK_RENDER_HIGHLIGHT_KIND=<kindID> (types mode: an
                // extension like "swift") exercises the kind-highlight
                // dimming in headless renders.
                let highlight = environment["NEODISK_RENDER_HIGHLIGHT_KIND"]
                    .map { TreemapHighlight.kind($0) }
                // NEODISK_RENDER_CLOUD_ONLY=0 turns cloud-only weighting off;
                // on by default to match the app's toolbar toggle (a no-op
                // for scans without cloud items).
                let includingCloudOnly = environment["NEODISK_RENDER_CLOUD_ONLY"] != "0"
                // NEODISK_RENDER_STYLE=flat renders the flat nested-box
                // style instead of the cushion default. Both styles sit on
                // the window background like the app (system appearance).
                let style = environment["NEODISK_RENDER_STYLE"]
                    .flatMap(TreemapStyle.init(rawValue:)) ?? .cushion
                let background: SIMD3<Float>
                if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                   let converted = NSColor.windowBackgroundColor.cgColor
                       .converted(to: srgb, intent: .defaultIntent, options: nil),
                   let components = converted.components, components.count >= 3 {
                    background = SIMD3<Float>(
                        Float(components[0]), Float(components[1]), Float(components[2])
                    )
                } else {
                    background = TreemapRasterTarget.backgroundRGB
                }
                let viewport = TreemapViewport(
                    scale: zoomScale,
                    origin: CGPoint(
                        x: originFraction.x * max(0, size.width * zoomScale - size.width),
                        y: originFraction.y * max(0, size.height * zoomScale - size.height)
                    )
                )
                let scene = TreemapScene.build(
                    store: store, rootID: store.root.id, style: style, size: size, catalog: catalog,
                    colorMode: colorMode,
                    highlight: highlight,
                    viewport: viewport,
                    includingCloudOnly: includingCloudOnly,
                    palette: palette,
                    background: background
                )
                let image = switch style {
                case .cushion:
                    CushionTreemapRenderer.render(
                        cells: scene.cells, bounds: scene.renderBounds, scale: 2,
                        background: background
                    )
                case .flat:
                    FlatTreemapRenderer.render(
                        cells: scene.cells, bounds: scene.renderBounds, scale: 2,
                        background: background
                    )
                }
                guard let image else {
                    FileHandle.standardError.write(Data("render failed\n".utf8))
                    return
                }

                let outputURL = URL(filePath: outputPath)
                guard let destination = CGImageDestinationCreateWithURL(
                    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
                ) else {
                    FileHandle.standardError.write(Data("cannot write \(outputPath)\n".utf8))
                    return
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    FileHandle.standardError.write(Data("PNG finalize failed\n".utf8))
                    return
                }

                let stats = snapshot.aggregateStats
                print("scanned \(stats.fileCount) files, \(stats.totalAllocatedSize) bytes")
                print("cells: \(scene.cells.count), kinds: \(catalog.stats.count)")
                print("wrote \(outputPath)")
                result = 0
            } catch {
                FileHandle.standardError.write(Data("scan failed: \(error)\n".utf8))
            }
        }

        semaphore.wait()
        return result
    }
}
