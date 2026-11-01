import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

// MARK: - Volume capacity bar

/// One segment per kind category, a neutral one for used-but-unscanned capacity, and the empty track for
/// free space. Under a scanned folder its categories alone fill the bar.
nonisolated struct VolumeBarData: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Identifiable {
        let id: String
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

    /// Sidebar-sized sibling of CloudSummaryStrip's bar; nil without any cloud-only bytes.
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
        let segments = VolumeCapacitySegments.make(
            space: space,
            sidecar: sidecar,
            scannedBytes: scannedBytes,
            palette: palette
        ).map { segment in
            Segment(
                id: segment.id,
                label: segment.label,
                size: segment.size,
                rgb: segment.rgb,
                fraction: segment.fraction
            )
        }
        return VolumeBarData(segments: segments, availableSize: space.availableCapacity)
    }

    /// A scanned folder's bar: its categories, filling the bar.
    static func composition(
        sidecar: KindStatsSidecar,
        scannedBytes: Int64,
        palette: VizPalette
    ) -> VolumeBarData {
        let segments = VolumeCapacitySegments.composition(
            sidecar: sidecar,
            scannedBytes: scannedBytes,
            palette: palette
        ).map { segment in
            Segment(
                id: segment.id,
                label: segment.label,
                size: segment.size,
                rgb: segment.rgb,
                fraction: segment.fraction
            )
        }
        return VolumeBarData(segments: segments, availableSize: nil)
    }
}

/// A capacity bar's hover bubble, in window coordinates. The sidebar's tooltip layer draws it: inside the List
/// cell the row would clip it.
struct VolumeBarBubble: Equatable {
    /// The row's target, so a late contract from one bar never hides another's bubble.
    let ownerID: String
    let label: String
    let size: Int64
    /// Center of the hovered stretch.
    let midX: CGFloat
    let barFrame: CGRect
    var isExpanded: Bool
}

struct VolumeCapacityBar: View {
    @Environment(\.neoTextScale) private var textScale

    /// Sentinel hover ID for the empty (free-space) track after the
    /// segments.
    private static let freeTrackID = "free-track"

    let data: VolumeBarData
    let ownerID: String
    var onBubble: (VolumeBarBubble) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The segment (or free track) the pointer is over.
    @State private var hoveredSegmentID: String?
    /// The last bubble reported. Outlives the hover so the contract animation keeps its content and place.
    @State private var bubble: VolumeBarBubble?
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
                        .onHover { hover(segment.id, isHovering: $0, bar: geometry.frame(in: .global)) }
                }
                // The empty track stands for free space; hover-sensitive so
                // it can answer with the available capacity.
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hover(Self.freeTrackID, isHovering: $0, bar: geometry.frame(in: .global)) }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
        }
        // Segments are the information here — a hairline bar next to
        // scaled text hides the small ones entirely.
        .frame(height: (5 * textScale).rounded())
        .onDisappear { contract(animated: false) }
    }

    /// Leaving contracts after a grace period, so hopping segments (enter may arrive after exit) moves the
    /// bubble instead of replaying the cycle. Only the expand and contract animate.
    private func hover(_ id: String, isHovering: Bool, bar: CGRect) {
        if isHovering {
            unhoverTask?.cancel()
            unhoverTask = nil
            hoveredSegmentID = id
            guard let next = bubble(for: id, bar: bar) else {
                contract(animated: true)
                return
            }
            if bubble?.isExpanded == true {
                report(next)
            } else {
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28)) { report(next) }
            }
        } else if hoveredSegmentID == id {
            unhoverTask?.cancel()
            unhoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                hoveredSegmentID = nil
                contract(animated: true)
            }
        }
    }

    private func contract(animated: Bool) {
        guard var collapsed = bubble, collapsed.isExpanded else { return }
        collapsed.isExpanded = false
        if animated {
            withAnimation(.easeIn(duration: 0.14)) { report(collapsed) }
        } else {
            report(collapsed)
        }
    }

    private func report(_ next: VolumeBarBubble) {
        bubble = next
        onBubble(next)
    }

    private func bubble(for id: String, bar: CGRect) -> VolumeBarBubble? {
        func make(_ label: String, _ size: Int64, midX: CGFloat) -> VolumeBarBubble {
            VolumeBarBubble(
                ownerID: ownerID, label: label, size: size, midX: bar.minX + midX, barFrame: bar, isExpanded: true
            )
        }
        if id == Self.freeTrackID {
            guard let available = data.availableSize, !data.segments.isEmpty else { return nil }
            let usedWidth = bar.width * data.segments.reduce(0) { $0 + $1.fraction }
            return make("Available", available, midX: (usedWidth + bar.width) / 2)
        }
        var x: CGFloat = 0
        for segment in data.segments {
            let width = bar.width * segment.fraction
            if segment.id == id {
                return make(segment.label, segment.size, midX: x + (width / 2))
            }
            x += width
        }
        return nil
    }
}

/// Draws a capacity bar's bubble above the bar, clamped to the bar's width while the tail keeps pointing at
/// the stretch. Hidden until its size is measured; only scale and opacity animate, so it plays in place.
struct VolumeBarBubbleOverlay: View {
    let bubble: VolumeBarBubble
    /// The overlay's own window-space origin, to bring the bubble's frames into it.
    let origin: CGPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tooltipSize: CGSize = .zero

    /// Gap between the tooltip's tail tip and the top of the bar.
    private static let tooltipGap: CGFloat = 6

    var body: some View {
        let bar = bubble.barFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        let midX = bubble.midX - origin.x
        let width = tooltipSize.width
        let offsetX = min(max(midX - (width / 2), bar.minX), max(bar.maxX - width, bar.minX))
        let tailX = width > 0 ? midX - offsetX : nil
        let anchor: UnitPoint = if let tailX, width > 0 { UnitPoint(x: tailX / width, y: 1) } else { .bottom }
        VolumeBarTooltip(label: bubble.label, size: bubble.size, tailX: tailX)
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: VolumeBarTooltipSizeKey.self, value: proxy.size)
            })
            .scaleEffect(bubble.isExpanded || reduceMotion ? 1 : 0.35, anchor: anchor)
            .opacity(tooltipSize == .zero || !bubble.isExpanded ? 0 : 1)
            // A bar scrolled to the top keeps its bubble inside the sidebar, over the bar.
            .offset(x: offsetX, y: max(bar.minY - tooltipSize.height - Self.tooltipGap, 0))
            .allowsHitTesting(false)
            .onPreferenceChange(VolumeBarTooltipSizeKey.self) { tooltipSize = $0 }
    }
}

/// Each bar offsets its bubble by this and keeps it hidden until the first measurement lands.
struct VolumeBarTooltipSizeKey: PreferenceKey {
    nonisolated static let defaultValue: CGSize = .zero

    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// Drawn as one path so fill, stroke and shadow stay continuous across the tail joint.
struct TooltipBubble<Content: View>: View {
    static var tailHeight: CGFloat { 5 }

    /// Tail tip x in bubble coordinates; nil centers it (pre-measurement).
    var tailX: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(Color(nsColor: .labelColor))
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
                    .neoFont(11, weight: .semibold)
                Text(verbatim: NeodiskFormatters.size(size))
                    .neoFont(10)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Rounded rectangle with a downward tail at `tailX`, drawn as one path so
/// fill, stroke, and shadow stay continuous across the tail joint.
struct TooltipBubbleShape: Shape {
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
