//
//  SidebarScanBar.swift
//  Neodisk
//
//  The striped progress bar a sidebar row shows in its capacity-bar slot
//  while that location is scanning off-screen (a background scan a
//  navigate-away demotion left running), plus its hover bubble.
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

/// The striped bar shown in a scanning row's capacity-bar slot. A leaf view
/// bound to the session's `ScanProgressState`, so the ~10Hz progress churn
/// re-renders only this bar — never the row or the List, which invalidate
/// solely when a scan starts or stops (a registry insert/remove). Hovering
/// shows the live percent and item count in the capacity bar's tooltip chrome.
struct SidebarScanBar: View {
    @ObservedObject var progress: ScanProgressState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var tooltipSize: CGSize = .zero

    /// Gap between the tooltip's tail tip and the top of the bar.
    private static let tooltipGap: CGFloat = 6

    var body: some View {
        StripedProgressBar(value: progress.metrics.progressFraction)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28)) {
                    isHovering = hovering
                }
            }
            .overlay(alignment: .top) { tooltip }
    }

    /// Centered above the bar; the tail points down at the bar's middle.
    /// Offsetting clear of the bar needs the bubble's height, so it reports
    /// its size via preference and stays hidden until measured.
    private var tooltip: some View {
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
        .offset(y: -(tooltipSize.height + Self.tooltipGap))
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
