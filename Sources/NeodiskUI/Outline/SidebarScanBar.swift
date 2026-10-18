// The progress bar a sidebar row shows while its location scans in the background, plus its hover bubble.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

/// View-free so its detail line can be unit-tested; the first line is a static "Scanning...".
struct SidebarScanTooltipData: Equatable {
    var progressFraction: Double
    var itemCount: Int

    /// Second line: "<percent> · <count> items", matching the capacity bar
    /// tooltip's number formatting.
    var detailText: String {
        AppStrings.plural(
            itemCount, one: "%@ · %@ item", other: "%@ · %@ items",
            progressFraction.formatted(.percent.precision(.fractionLength(0))),
            itemCount.formatted()
        )
    }
}

/// Kept out of SidebarPane's state: frames change every scroll tick, which would re-run the whole pane
/// body. Only the tooltip layer observes this.
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

/// Bound to the session's progress state so ~10Hz churn re-renders only this bar, never the row or List.
/// Frame and hover reports go to `SidebarScanTooltipStore` for the same reason.
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

/// The only observer of the tooltip store. Bar frames arrive in global coordinates (the leaf is hosted in
/// AppKit's table), so they're converted back into overlay space.
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

/// Lives in the sidebar overlay rather than the List cell so the bubble isn't clipped by the row.
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
                    .neoFont(11, weight: .semibold)
                Text(verbatim: data.detailText)
                    .neoFont(10)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
