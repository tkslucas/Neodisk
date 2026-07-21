//
//  VolumeCapacityBar.swift
//  Neodisk
//
//  The macOS-storage-style capacity bar shown under a sidebar row: its
//  data model (VolumeBarData), the bar view, and the hover tooltip
//  (bubble shape + size preference). Used by SidebarTargetRow.
//

import AppKit
import SwiftUI
import NeodiskKit

// MARK: - Volume capacity bar

/// The macOS-storage-style bar under a volume row: one segment per file
/// kind category (same colors as the Kinds tab, palette-aware), a neutral
/// segment for used-but-unscanned capacity (hidden space / other users),
/// and the empty track standing for free space. `.empty` before any scan.
nonisolated struct VolumeBarData: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Identifiable {
        let id: String
        /// Localization key for the hover tooltip: a kind category display
        /// name, "Hidden Space" for the unscanned tail, or the cloud bar's
        /// "On this Mac" / "Cloud-only".
        let label: String
        let size: Int64
        let rgb: SIMD3<Float>
        /// Fraction of the volume's total capacity.
        let fraction: Double
        /// Overrides the rgb-derived fill — the cloud bar uses the dynamic
        /// accent color, which has no fixed rgb.
        var explicitColor: Color?
        /// Cloud-only segments wear the shared dataless hatch.
        var isHatched = false

        var color: Color {
            explicitColor ?? Color(rgb: rgb)
        }
    }

    let segments: [Segment]
    /// Free capacity (important-usage) for the empty track's tooltip; nil
    /// hides that tooltip.
    let availableSize: Int64?

    static let empty = VolumeBarData(segments: [], availableSize: nil)

    /// The two-segment on-this-Mac / cloud-only proportion bar for scanned
    /// cloud locations — the sidebar-sized sibling of CloudSummaryStrip's
    /// bar, sharing its colors and the dataless hatch. Nil without any
    /// cloud-only bytes (nothing worth a bar).
    static func cloudProportions(onThisMac: Int64, cloudOnly: Int64) -> VolumeBarData? {
        guard cloudOnly > 0 else { return nil }
        let total = Double(onThisMac) + Double(cloudOnly)
        return VolumeBarData(
            segments: [
                Segment(
                    id: "on-this-mac",
                    label: "On this Mac",
                    size: onThisMac,
                    rgb: .zero,
                    fraction: Double(onThisMac) / total,
                    explicitColor: .accentColor
                ),
                Segment(
                    id: "cloud-only",
                    label: "Cloud-only",
                    size: cloudOnly,
                    rgb: .zero,
                    fraction: Double(cloudOnly) / total,
                    explicitColor: .accentColor.opacity(0.3),
                    isHatched: true
                ),
            ],
            availableSize: nil
        )
    }

    static func make(
        space: VolumeSpaceInfo?,
        sidecar: KindStatsSidecar,
        scannedBytes: Int64,
        palette: VizPalette
    ) -> VolumeBarData {
        guard let space, space.totalCapacity > 0 else {
            return .empty
        }
        let total = space.totalCapacity

        var sizeByKindID: [String: Int64] = [:]
        for stat in sidecar.stats(for: .categories) where stat.size > 0 {
            sizeByKindID[stat.kindID, default: 0] += stat.size
        }
        // Scanned bytes the kind stats don't cover (directory overhead,
        // synthetic nodes) fold into the catch-all category, so the colored
        // segments tile the scanned tree exactly and the hidden tail below
        // states the same figure as the sunburst legend.
        let categorizedBytes = sizeByKindID.values.reduce(0, +)
        let uncategorized = scannedBytes - categorizedBytes
        if uncategorized > 0 {
            sizeByKindID["cat-other", default: 0] += uncategorized
        }

        var segments: [Segment] = sizeByKindID
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { kindID, size in
                Segment(
                    id: kindID,
                    label: FileKindClassifier.kind(forID: kindID, mode: .categories).displayName,
                    size: size,
                    rgb: palette.categoryRGB[kindID] ?? FileKindCatalog.otherRGB,
                    fraction: Double(size) / Double(total)
                )
            }

        // Used capacity the scan didn't account for (unreadable paths,
        // other users' homes, snapshot-held blocks): a neutral tail
        // segment, like macOS "System Data" — same formula everywhere.
        if let hidden = space.hiddenSpaceBytes(scannedBytes: max(scannedBytes, categorizedBytes)) {
            segments.append(Segment(
                id: "unscanned",
                label: "Hidden Space",
                size: hidden,
                rgb: FileKindCatalog.otherRGB,
                fraction: Double(hidden) / Double(total)
            ))
        }

        return VolumeBarData(segments: segments, availableSize: space.availableCapacity)
    }
}

struct VolumeCapacityBar: View {
    /// Sentinel hover ID for the empty (free-space) track after the
    /// segments.
    private static let freeTrackID = "free-track"
    /// Gap between the tooltip's tail tip and the top of the bar.
    private static let tooltipGap: CGFloat = 6

    let data: VolumeBarData

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The segment (or free track) the pointer is over; drives the bubble's
    /// expanded/contracted state.
    @State private var hoveredSegmentID: String?
    /// The segment the bubble describes. Outlives `hoveredSegmentID` so the
    /// contract animation keeps its content and place instead of vanishing.
    @State private var shownSegmentID: String?
    /// Measured bubble size; the tooltip stays invisible until the first
    /// measurement lands so it never flashes at an unclamped position.
    @State private var tooltipSize: CGSize = .zero
    /// Pending delayed unhover; sliding across adjacent segments cancels it
    /// so the bubble never contracts and re-expands mid-bar.
    @State private var unhoverTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(data.segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .overlay {
                            if segment.isHatched {
                                DatalessHatchOverlay()
                            }
                        }
                        .frame(width: geometry.size.width * segment.fraction)
                        .onHover { hover(segment.id, isHovering: $0) }
                }
                // The empty track stands for free space; hover-sensitive so
                // it can answer with the available capacity.
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hover(Self.freeTrackID, isHovering: $0) }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(alignment: .topLeading) {
                // Mounted while `shownSegmentID` is set (through the whole
                // contract animation); only scale and opacity animate, so
                // the bubble always plays the same expand/contract in the
                // same segment-anchored place.
                if let info = shownInfo(barWidth: geometry.size.width) {
                    tooltip(
                        info: info,
                        barWidth: geometry.size.width,
                        isExpanded: hoveredSegmentID != nil
                    )
                }
            }
        }
        .frame(height: 5)
        .onPreferenceChange(VolumeBarTooltipSizeKey.self) { tooltipSize = $0 }
    }

    /// Entering expands the bubble; leaving contracts it after a short
    /// grace period, so hopping to the next segment (whose enter event may
    /// arrive after this one's exit) repositions the bubble instead of
    /// replaying the contract/expand cycle. Only the expanded/contracted
    /// flip is animated — content and position swap instantly.
    private func hover(_ id: String, isHovering: Bool) {
        if isHovering {
            unhoverTask?.cancel()
            unhoverTask = nil
            shownSegmentID = id
            if hoveredSegmentID == nil {
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28)) {
                    hoveredSegmentID = id
                }
            } else {
                hoveredSegmentID = id
            }
        } else if hoveredSegmentID == id {
            unhoverTask?.cancel()
            unhoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.14)) {
                    hoveredSegmentID = nil
                }
            }
        }
    }

    // MARK: - Tooltip

    private struct HoverInfo {
        let label: String
        let size: Int64
        /// Center of the hovered stretch, in bar coordinates.
        let midX: CGFloat
    }

    private func shownInfo(barWidth: CGFloat) -> HoverInfo? {
        guard let shownSegmentID else { return nil }
        if shownSegmentID == Self.freeTrackID {
            guard let available = data.availableSize, !data.segments.isEmpty else { return nil }
            let usedWidth = barWidth * data.segments.reduce(0) { $0 + $1.fraction }
            return HoverInfo(label: "Available", size: available, midX: (usedWidth + barWidth) / 2)
        }
        var x: CGFloat = 0
        for segment in data.segments {
            let width = barWidth * segment.fraction
            if segment.id == shownSegmentID {
                return HoverInfo(label: segment.label, size: segment.size, midX: x + (width / 2))
            }
            x += width
        }
        return nil
    }

    /// The bubble above the hovered stretch, macOS-storage-bar style. The
    /// bubble centers on the stretch but clamps to the bar's width; the
    /// tail keeps pointing at the stretch even when the bubble clamps.
    /// Offsets need the bubble's size, so it reports it via preference and
    /// hides until measured. Position is never animated: expand/contract is
    /// a scale out of the tail tip plus a fade, identical every time for a
    /// given segment.
    private func tooltip(info: HoverInfo, barWidth: CGFloat, isExpanded: Bool) -> some View {
        let width = tooltipSize.width
        let offsetX = min(max(info.midX - (width / 2), 0), max(barWidth - width, 0))
        let tailX = width > 0 ? info.midX - offsetX : nil
        let anchor: UnitPoint = if let tailX, width > 0 {
            UnitPoint(x: tailX / width, y: 1)
        } else {
            .bottom
        }
        return VolumeBarTooltip(
            label: info.label,
            size: info.size,
            tailX: tailX
        )
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: VolumeBarTooltipSizeKey.self, value: proxy.size)
        })
        .scaleEffect(isExpanded || reduceMotion ? 1 : 0.35, anchor: anchor)
        .opacity(tooltipSize == .zero || !isExpanded ? 0 : 1)
        .offset(x: offsetX, y: -(tooltipSize.height + Self.tooltipGap))
        .allowsHitTesting(false)
    }
}

/// Reports the measured capacity tooltip size so it can be offset clear of
/// the bar and stay hidden until the first measurement lands.
private struct VolumeBarTooltipSizeKey: PreferenceKey {
    nonisolated static let defaultValue: CGSize = .zero

    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// Capacity tooltip chrome: content in a rounded card with a downward tail at
/// `tailX`, drawn as one path so fill, stroke, and shadow stay continuous.
private struct TooltipBubble<Content: View>: View {
    static var tailHeight: CGFloat { 5 }

    /// Tail tip x in bubble coordinates; nil centers it (pre-measurement).
    var tailX: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .padding(.bottom, Self.tailHeight)
            .background {
                let bubble = TooltipBubbleShape(tailHeight: Self.tailHeight, tailX: tailX)
                bubble
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(bubble.stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
            }
    }
}

/// The hover bubble for one capacity-bar stretch: kind name over its size,
/// in the shared bubble with a tail pointing down at the hovered spot.
private struct VolumeBarTooltip: View {
    let label: String
    let size: Int64
    /// Tail tip x in bubble coordinates; nil centers it (pre-measurement).
    let tailX: CGFloat?

    var body: some View {
        TooltipBubble(tailX: tailX) {
            VStack(spacing: 1) {
                Text(LocalizedStringKey(label))
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: NeodiskFormatters.size(size))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Rounded rectangle with a downward tail at `tailX`, drawn as one path so
/// fill, stroke, and shadow stay continuous across the tail joint.
private struct TooltipBubbleShape: Shape {
    var cornerRadius: CGFloat = 7
    var tailWidth: CGFloat = 12
    var tailHeight: CGFloat
    /// Tail tip x; nil centers it. Clamped clear of the rounded corners.
    var tailX: CGFloat?

    nonisolated func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height - tailHeight
        )
        let halfTail = tailWidth / 2
        let minTip = rect.minX + cornerRadius + halfTail
        let maxTip = rect.maxX - cornerRadius - halfTail
        let tip = min(max(tailX ?? rect.midX, minTip), max(maxTip, minTip))
        var path = Path()
        path.addRoundedRect(
            in: body,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        path.move(to: CGPoint(x: tip - halfTail, y: body.maxY))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: tip + halfTail, y: body.maxY))
        path.closeSubpath()
        return path
    }
}
