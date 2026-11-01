// The dev window around the canvas, and the scripted benchmark that drives it: hover sweeps, live resizing and
// drill transitions, timed per frame with the device drained so software rendering counts.

import CNeodiskCanvas
import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit
import WinSDK

@MainActor
final class DemoWindow {
    let hwnd: HWND
    private(set) var canvas: VizCanvas!
    let model: DemoModel
    private let title: String

    private static let className: [WCHAR] = Array("NeodiskCanvasDemo".utf16) + [0]

    init(model: DemoModel, title: String) {
        self.model = model
        self.title = title
        Self.className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = demoWindowProc
            windowClass.hInstance = GetModuleHandleW(nil)
            windowClass.hCursor = LoadCursorW(nil, IDC_ARROW_POINTER)
            windowClass.lpszClassName = name.baseAddress
            _ = RegisterClassExW(&windowClass)
        }
        let titleUnits = Array("Neodisk canvas".utf16) + [0]
        hwnd = Self.className.withUnsafeBufferPointer { name in
            titleUnits.withUnsafeBufferPointer { titleBuffer in
                CreateWindowExW(
                    0, name.baseAddress, titleBuffer.baseAddress, DWORD(WS_OVERLAPPEDWINDOW),
                    40, 30, 1100, 720, nil, nil, GetModuleHandleW(nil), nil
                )!
            }
        }
        canvas = VizCanvas(parent: hwnd, model: model)
        model.canvas = canvas
        model.onStatus = { [weak self] text in self?.setTitle(text) }
        model.onKey = { [weak self] vk, ctrl in self?.handleKey(vk, ctrl: ctrl) ?? false }
        DemoWindow.current = self
        _ = ShowWindow(hwnd, SW_SHOWNORMAL)
        layout()
        if let canvasWindow = canvas.hwnd { _ = SetFocus(canvasWindow) }
        canvas.modelDidChange()
    }

    nonisolated(unsafe) static var current: DemoWindow?

    func layout() {
        var rect = RECT()
        _ = GetClientRect(hwnd, &rect)
        if let canvasWindow = canvas?.hwnd {
            _ = MoveWindow(canvasWindow, 0, 0, rect.right - rect.left, rect.bottom - rect.top, true)
        }
    }

    private func setTitle(_ text: String?) {
        let units = Array((text ?? title).utf16) + [0]
        units.withUnsafeBufferPointer { _ = SetWindowTextW(hwnd, $0.baseAddress) }
    }

    /// T treemap, B sunburst, F flat or cushion, L light or dark, K/A/R kind, age or branch colors.
    private func handleKey(_ vk: UInt32, ctrl: Bool) -> Bool {
        guard !ctrl else { return false }
        switch vk {
        case 0x54: canvas.mode = .treemap
        case 0x42: canvas.mode = .sunburst
        case 0x46: model.treemapStyle = model.treemapStyle == .flat ? .cushion : .flat
        case 0x4C: model.isDarkTheme.toggle()
        case 0x4B: model.colorMode = .kind
        case 0x41: model.colorMode = .age(referenceDate: Date())
        case 0x52: model.colorMode = .branch
        default: return false
        }
        canvas.modelDidChange()
        return true
    }

    func runLoop() -> Int32 {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
        }
        return 0
    }

    /// Handles what's queued, for scripted runs.
    func pump() {
        var message = MSG()
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
        }
    }

    /// Pumps until `condition` holds or `seconds` pass.
    @discardableResult
    func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            if Clock.milliseconds(since: start) > seconds * 1000 { return false }
            pump()
            Sleep(1)
        }
        pump()
        return true
    }
}

private let demoWindowProc: WNDPROC = { hwnd, message, wParam, lParam in
    switch Int32(message) {
    case WM_SIZE:
        MainActor.assumeIsolated { DemoWindow.current?.layout() }
        return 0
    case WM_SETFOCUS:
        MainActor.assumeIsolated {
            if let canvas = DemoWindow.current?.canvas?.hwnd { _ = SetFocus(canvas) }
        }
        return 0
    case WM_DESTROY:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

@MainActor
struct CanvasBenchmark {
    let window: DemoWindow
    let model: DemoModel
    let label: String
    let adapter: (name: String, isSoftware: Bool)

    private var canvas: VizCanvas { window.canvas }

    func run(reportPath: String) -> Int32 {
        var lines = ["tree: \(label)", "adapter: \(adapter.name) (software: \(adapter.isSoftware))"]
        canvas.presentMode = .immediate
        canvas.timesFrames = true
        let stats = canvas.stats

        func settle() -> Bool {
            window.wait(seconds: 120) {
                canvas.mode == .treemap ? canvas.treemap.hasFrame && !canvas.treemap.isRenderPending
                    : canvas.sunburst.hasFrame && !canvas.sunburst.isRenderPending
            }
        }

        func clientSize() -> String {
            var rect = RECT()
            if let hwnd = canvas.hwnd { _ = GetClientRect(hwnd, &rect) }
            return "\(rect.right - rect.left)x\(rect.bottom - rect.top) px"
        }

        let views: [(String, TreemapStyle, VizCanvas.Mode)] = [
            ("cushion", .cushion, .treemap), ("flat", .flat, .treemap), ("sunburst", .cushion, .sunburst),
        ]
        for (name, style, mode) in views {
            stats.reset()
            model.treemapStyle = style
            canvas.mode = mode
            canvas.modelDidChange()
            let first = ContinuousClock.now
            guard settle() else {
                lines.append("\(name): first frame never landed")
                continue
            }
            lines.append(String(format: "\n[%@] canvas %@, first frame landed after %.0f ms", name, clientSize(),
                                Clock.milliseconds(since: first)))
            let renderKey = mode == .treemap ? "treemap.render" : "sunburst.render"
            let frameKey = mode == .treemap ? "frame.treemap" : "frame.sunburst"
            for key in [renderKey, mode == .treemap ? "treemap.scene" : "sunburst.layout",
                        mode == .treemap ? "treemap.raster" : "sunburst.raster", "treemap.labels",
                        "treemap.upload", "treemap.labelImage", "sunburst.upload"] where !stats.values(key).isEmpty {
                lines.append("  first " + stats.summary(key))
            }
            let cells = stats.values(mode == .treemap ? "treemap.cells" : "sunburst.segments").last ?? 0
            lines.append(String(format: "  %@: %.0f", mode == .treemap ? "cells" : "segments", cells))

            // Hover: every move hit-tests and repaints overlays over the cached raster.
            stats.reset()
            var hoverMs: [Double] = []
            for index in 0..<400 {
                let point = (mode == .treemap ? canvas.treemap.benchmarkPoint(index * 7919)
                    : canvas.sunburst.benchmarkPoint(index * 7919)) ?? .zero
                let start = ContinuousClock.now
                canvas.pointerMoved(to: point)
                canvas.render()
                // This move's frame is on screen; drop the repaint the move queued.
                if let hwnd = canvas.hwnd { _ = ValidateRect(hwnd, nil) }
                hoverMs.append(Clock.milliseconds(since: start))
                window.pump()
            }
            lines.append("  hover " + Self.summary(hoverMs) + " (hit-test + overlay frame)")
            lines.append("  hover " + stats.summary(frameKey))
            lines.append("  hover " + stats.summary(frameKey + ".cpu"))
            lines.append("  hover re-rasters: \(stats.values(renderKey).count)")
            // The same frames drawn but not presented: the device's own cost, without waiting on composition.
            stats.reset()
            canvas.presentMode = .none
            for index in 0..<200 {
                let point = (mode == .treemap ? canvas.treemap.benchmarkPoint(index * 7919)
                    : canvas.sunburst.benchmarkPoint(index * 7919)) ?? .zero
                canvas.pointerMoved(to: point)
                canvas.render()
                if let hwnd = canvas.hwnd { _ = ValidateRect(hwnd, nil) }
                window.pump()
            }
            canvas.presentMode = .immediate
            lines.append("  draw only (no present) " + stats.summary(frameKey))
            stats.reset()


            // Live resize: the old raster stretches each frame while renders chase the latest size.
            stats.reset()
            var rect = RECT()
            _ = GetWindowRect(window.hwnd, &rect)
            let width = rect.right - rect.left
            let height = rect.bottom - rect.top
            var resizeMs: [Double] = []
            for step in 0..<60 {
                let delta = Int32(step < 30 ? -step * 8 : (step - 60) * 8)
                let start = ContinuousClock.now
                _ = SetWindowPos(window.hwnd, nil, 0, 0, width + delta, height + delta / 2,
                             UINT(SWP_NOMOVE | SWP_NOZORDER))
                resizeMs.append(Clock.milliseconds(since: start))
                window.pump()
                Sleep(16)
            }
            let settleStart = ContinuousClock.now
            _ = settle()
            lines.append("  resize " + Self.summary(resizeMs) + " (WM_SIZE + buffer resize + stretched frame)")
            lines.append("  resize " + stats.summary(frameKey))
            lines.append("  resize " + stats.summary(frameKey + ".cpu"))
            lines.append("  resize " + stats.summary("resize.buffers"))
            lines.append("  resize " + stats.summary(renderKey) + " (background renders while dragging)")
            lines.append(String(format: "  resize settled %.0f ms after the last step", Clock.milliseconds(since: settleStart)))

            // Transitions: the sunburst's drill animation, the cushion's wheel zoom glide.
            stats.reset()
            if mode == .sunburst, let target = canvas.sunburst.benchmarkDrillTarget {
                _ = model.drillIn(to: target)
                let start = ContinuousClock.now
                window.wait(seconds: 5) { !canvas.sunburst.isAnimating }
                lines.append(String(format: "  drill in: %d frames in %.0f ms", stats.values(frameKey).count,
                                    Clock.milliseconds(since: start)))
                lines.append("  drill in " + stats.summary(frameKey))
                lines.append("  drill in " + stats.summary(frameKey + ".cpu"))
                _ = settle()
                stats.reset()
                model.focusOut()
                let outStart = ContinuousClock.now
                window.wait(seconds: 5) { !canvas.sunburst.isAnimating }
                lines.append(String(format: "  drill out: %d frames in %.0f ms", stats.values(frameKey).count,
                                    Clock.milliseconds(since: outStart)))
                lines.append("  drill out " + stats.summary(frameKey))
                lines.append("  drill out " + stats.summary(frameKey + ".cpu"))
                lines.append("  drill " + stats.summary(renderKey))
            } else if mode == .treemap, style == .cushion {
                let center = CGPoint(x: canvas.viewSize.width / 2, y: canvas.viewSize.height / 2)
                _ = canvas.treemap.wheel(notches: 4, horizontal: false, at: center, ctrl: true, shift: false)
                let start = ContinuousClock.now
                window.wait(seconds: 5) { !canvas.treemap.isAnimating }
                lines.append(String(format: "  zoom glide: %d frames in %.0f ms", stats.values(frameKey).count,
                                    Clock.milliseconds(since: start)))
                lines.append("  zoom glide " + stats.summary(frameKey))
                lines.append("  zoom glide " + stats.summary(frameKey + ".cpu"))
                _ = settle()
                lines.append("  zoom " + stats.summary(renderKey) + " (renders chasing the glide)")
                _ = canvas.keyDown(VK_ESCAPE)
                _ = settle()
            } else if mode == .treemap, let target = model.store?.children(of: model.store?.rootID).first(where: \.isDirectory)?.id {
                // Flat has no animation: time drilling in until the new map is on screen.
                let start = ContinuousClock.now
                _ = model.drillIn(to: target)
                _ = settle()
                canvas.render()
                lines.append(String(format: "  drill in to new frame on screen: %.0f ms", Clock.milliseconds(since: start)))
                model.focusOut()
                _ = settle()
            }
        }
        let report = lines.joined(separator: "\n") + "\n"
        _ = FileManager.default.createFile(atPath: reportPath, contents: Data(report.utf8))
        CanvasLog.write(report)
        _ = DestroyWindow(window.hwnd)
        return 0
    }

    static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "no samples" }
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "n=%d avg=%.2f ms p95=%.2f ms max=%.2f ms", sorted.count, average, p95, sorted.last ?? 0)
    }
}
