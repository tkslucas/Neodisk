//
//  SidebarScanBar.swift
//  Neodisk
//
//  The striped progress bar a sidebar row shows in its capacity-bar slot
//  while that location is scanning off-screen (a background scan a
//  navigate-away demotion left running), plus its hover bubble and the
//  store + overlay layer that draw the bubble above the List's cells.
//

import SwiftUI
import NeodiskKit

/// Content of a sidebar row's background-scan hover bubble, independent of any
/// view so its detail line can be unit-tested. The first line is a static
/// "Scanning…"; this carries the live second line.
struct SidebarScanTooltipData: Equatable {
    var progressFraction: Double
    var itemCount: Int

    /// Second line: "<percent> · <count> items", matching the capacity bar
    /// tooltip's number formatting.
    var detailText: String {
        String(
            format: NSLocalizedString(
                "%@ · %@ items",
                comment: "Sidebar background-scan tooltip detail: scan percent and item count"
            ),
            progressFraction.formatted(.percent.precision(.fractionLength(0))),
            itemCount.formatted()
        )
    }
}

/// Frames and hover state for the visible background-scan bars, kept outside
/// SidebarPane's view state on purpose: a bar's frame changes on every scroll
/// tick, and routing that through pane `@State` would re-run the whole pane
/// body (List included) per tick. Only `SidebarScanTooltipLayer` observes
/// this store, so frame churn re-renders just the bubble layer.
@MainActor
final class SidebarScanTooltipStore: ObservableObject {
    /// Global frames of visible background-scan bars, keyed by target ID.
    @Published private(set) var barFrames: [String: CGRect] = [:]
    /// The bar currently hovered, if any.
    @Published private(set) var hoveredTargetID: String?

    /// Records a bar's global frame, or forgets the bar on nil (its row left
    /// the table). Never animated: the bubble must track scrolling exactly.
    func setFrame(_ frame: CGRect?, forTargetID targetID: String) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            if let frame {
                guard barFrames[targetID] != frame else { return }
                barFrames[targetID] = frame
            } else {
                barFrames.removeValue(forKey: targetID)
                if hoveredTargetID == targetID {
                    hoveredTargetID = nil
                }
            }
        }
    }

    /// Ordering-safe hover update: a late exit event from one bar must not
    /// clobber a fresh hover on another.
    func setHovering(_ hovering: Bool, targetID: String, reduceMotion: Bool) {
        guard hovering || hoveredTargetID == targetID else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28)) {
            hoveredTargetID = hovering ? targetID : nil
        }
    }
}

/// The striped bar shown in a scanning row's capacity-bar slot. A leaf view
/// bound to the session's `ScanProgressState`, so the ~10Hz progress churn
/// re-renders only this bar — never the row or the List, which invalidate
/// solely when a scan starts or stops (a registry insert/remove). Hovering
/// shows the live percent and item count in the capacity bar's tooltip
/// chrome; frame and hover reports flow to `SidebarScanTooltipStore`, so
/// they never invalidate the row or the List either.
struct SidebarScanBar: View {
    let targetID: String
    @ObservedObject var progress: ScanProgressState
    var onFrameChange: (String, CGRect?) -> Void
    var onHover: (String, Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        StripedProgressBar(value: progress.metrics.progressFraction)
            .contentShape(Rectangle())
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { onFrameChange(targetID, frame) }
                        .onChange(of: frame) { _, newFrame in
                            onFrameChange(targetID, newFrame)
                        }
                }
            }
            .onHover { hovering in
                isHovering = hovering
                onHover(targetID, hovering)
            }
            .onDisappear {
                if isHovering {
                    onHover(targetID, false)
                }
                onFrameChange(targetID, nil)
            }
    }
}

/// The List overlay that draws every scan bubble; the only observer of the
/// tooltip store, so per-scroll-tick frame updates re-render this layer
/// alone. Bar frames arrive in global coordinates because the reporting leaf
/// is hosted inside AppKit's table; convert them back into overlay space.
struct SidebarScanTooltipLayer: View {
    @ObservedObject var store: SidebarScanTooltipStore
    /// Resolves a target's running background scan; nil once it stops.
    let progressFor: (String) -> ScanProgressState?

    var body: some View {
        GeometryReader { proxy in
            let overlayFrame = proxy.frame(in: .global)
            ZStack(alignment: .topLeading) {
                ForEach(store.barFrames.keys.sorted(), id: \.self) { targetID in
                    if let globalBarFrame = store.barFrames[targetID],
                       let progress = progressFor(targetID) {
                        let localBarFrame = globalBarFrame.offsetBy(
                            dx: -overlayFrame.minX,
                            dy: -overlayFrame.minY
                        )
                        SidebarScanTooltipOverlay(
                            progress: progress,
                            barFrame: localBarFrame,
                            isHovering: store.hoveredTargetID == targetID
                        )
                        .zIndex(store.hoveredTargetID == targetID ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// The bubble itself lives in the sidebar overlay rather than this bar's List
/// cell. Its global bar frame is converted to overlay coordinates by the
/// parent, so the same centered anchor is preserved without row clipping.
struct SidebarScanTooltipOverlay: View {
    @ObservedObject var progress: ScanProgressState
    let barFrame: CGRect
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tooltipSize: CGSize = .zero

    /// Gap between the tooltip's tail tip and the top of the bar.
    private static let tooltipGap: CGFloat = 6

    var body: some View {
        SidebarScanTooltip(
            data: SidebarScanTooltipData(
                progressFraction: progress.metrics.progressFraction,
                itemCount: progress.metrics.filesVisited
            )
        )
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: VolumeBarTooltipSizeKey.self, value: proxy.size)
        })
        .scaleEffect(isHovering || reduceMotion ? 1 : 0.35, anchor: .bottom)
        .opacity(tooltipSize == .zero || !isHovering ? 0 : 1)
        .offset(
            x: barFrame.midX - (tooltipSize.width / 2),
            y: barFrame.minY - tooltipSize.height - Self.tooltipGap
        )
        .allowsHitTesting(false)
        .onPreferenceChange(VolumeBarTooltipSizeKey.self) { tooltipSize = $0 }
    }
}

/// The hover bubble for a sidebar row's background scan: "Scanning…" over the
/// live percent and item count, in the shared capacity-bar tooltip chrome.
private struct SidebarScanTooltip: View {
    let data: SidebarScanTooltipData

    var body: some View {
        TooltipBubble(tailX: nil) {
            VStack(spacing: 1) {
                Text("Scanning…")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: data.detailText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
