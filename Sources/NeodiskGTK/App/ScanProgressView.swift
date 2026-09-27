//
//  ScanProgressView.swift
//  NeodiskGTK
//
//  The scan progress strip under the header bar. The product rules are the
//  Mac's: the bar is determinate always, never moves backward within a scan,
//  and is full exactly when the scan is done; liveness is the drifting
//  diagonal-stripe sheen on the fill, which drifts while work runs and
//  freezes when it stops. The stripes are a GPU repeating gradient animated
//  from the frame clock.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class ScanProgressView: CanvasDelegate {
    let widget: GPtr
    private let model: AppModel
    private let bar = Canvas()
    private let caption: GPtr
    private var fraction = 0.0
    private var scanKey: String?
    private var tickID: UInt32 = 0
    private var stripePhase = 0.0
    private var lastFrameTime: Int64 = 0
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model
        caption = Widgets.label("", classes: ["dim-label", "neodisk-caption", "neodisk-numeric"], ellipsize: true)
        gtk_widget_set_size_request(ptr(bar.widget), -1, 6)
        gtk_widget_set_vexpand(ptr(bar.widget), gbool(false))
        gtk_widget_set_focusable(ptr(bar.widget), gbool(false))
        Widgets.setMargins(bar.widget, top: 6, start: 12, end: 12)
        widget = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 2, [bar.widget, caption])
        Widgets.addClasses(caption, ["neodisk-progress-caption"])
        bar.delegate = self
        Widgets.setVisible(widget, false)

        tokens.append(track { [unowned self] in
            self.update()
        })
    }

    private func update() {
        let running = model.isScanning
        let key = running ? "\(model.target?.id ?? "")|\(model.isRefreshing)" : nil
        if key != scanKey {
            // A new scan session starts from empty; within one, the bar
            // only ever grows.
            scanKey = key
            fraction = 0
        }
        Widgets.setVisible(widget, running)
        guard running else {
            stopAnimating()
            return
        }
        let metrics = model.metrics
        fraction = max(fraction, min(1, max(0, metrics.progressFraction)))
        gtk_label_set_text(ptr(caption), captionText(metrics))
        startAnimating()
        bar.queueDraw()
    }

    private func captionText(_ metrics: ScanMetrics) -> String {
        if metrics.isFinalizing {
            return L("Finishing up…")
        }
        if metrics.isMergingChanges {
            return L("Merging changes…")
        }
        let counts = L(
            "%@ files · %@",
            metrics.filesVisited.formatted(),
            NeodiskFormatters.size(metrics.bytesDiscovered)
        )
        let path = DisplayFormatters.displayPath(metrics.currentPath)
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return path.isEmpty ? "\(percent) · \(counts)" : "\(percent) · \(counts) · \(path)"
    }

    // MARK: - Animation

    private func startAnimating() {
        guard tickID == 0 else { return }
        lastFrameTime = 0
        tickID = addTickCallback(bar.widget) { [weak self] frameTime in
            guard let self else { return false }
            if self.lastFrameTime != 0 {
                // 18 points per second, like the Mac sheen.
                self.stripePhase += Double(frameTime - self.lastFrameTime) / 1_000_000 * 18
            }
            self.lastFrameTime = frameTime
            self.bar.queueDraw()
            return true
        }
    }

    private func stopAnimating() {
        guard tickID != 0 else { return }
        gtk_widget_remove_tick_callback(ptr(bar.widget), tickID)
        tickID = 0
    }

    // MARK: - CanvasDelegate

    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int) {}

    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double) {
        let track = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = Float(height / 2)
        var rounded = GskRoundedRect()
        var bounds = grapheneRect(track)
        gsk_rounded_rect_init_from_rect(&rounded, &bounds, radius)
        gtk_snapshot_push_rounded_clip(ptr(snapshot), &rounded)
        defer { gtk_snapshot_pop(ptr(snapshot)) }

        Snapshot.fill(snapshot, track, RGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.2))
        let fill = CGRect(x: 0, y: 0, width: width * fraction, height: height)
        guard fill.width > 0 else { return }
        Snapshot.fill(snapshot, fill, Accent.color)

        // Diagonal stripes: a 45° repeating gradient with hard stops.
        let period = 10.0
        let offset = stripePhase.truncatingRemainder(dividingBy: period)
        var fillBounds = grapheneRect(fill)
        var start = graphene_point_t(x: Float(offset), y: 0)
        var end = graphene_point_t(x: Float(offset + period / 2), y: Float(period / 2))
        let clear = RGBA(red: 1, green: 1, blue: 1, alpha: 0).gdk
        let sheen = RGBA(red: 1, green: 1, blue: 1, alpha: 0.22).gdk
        var stops: [GskColorStop] = [
            GskColorStop(offset: 0, color: clear),
            GskColorStop(offset: 0.5, color: clear),
            GskColorStop(offset: 0.5, color: sheen),
            GskColorStop(offset: 1, color: sheen),
        ]
        gtk_snapshot_append_repeating_linear_gradient(ptr(snapshot), &fillBounds, &start, &end, &stops, gsize(stops.count))
    }
}

// MARK: - Tick callbacks

private final class TickBox {
    let handler: @MainActor (Int64) -> Bool
    init(_ handler: @escaping @MainActor (Int64) -> Bool) { self.handler = handler }
}

/// Runs `handler` on every frame of `widget` until it returns false;
/// the argument is the frame clock's time in microseconds.
@MainActor
func addTickCallback(_ widget: GPtr, _ handler: @escaping @MainActor (Int64) -> Bool) -> UInt32 {
    gtk_widget_add_tick_callback(
        ptr(widget),
        { _, clock, data in
            nonisolated(unsafe) let clock = clock
            nonisolated(unsafe) let data = data
            return MainActor.assumeIsolated {
                let box = Unmanaged<TickBox>.fromOpaque(data!).takeUnretainedValue()
                return gbool(box.handler(Int64(gdk_frame_clock_get_frame_time(clock))))
            }
        },
        Unmanaged.passRetained(TickBox(handler)).toOpaque(),
        { data in
            guard let data else { return }
            Unmanaged<TickBox>.fromOpaque(data).release()
        }
    )
}
