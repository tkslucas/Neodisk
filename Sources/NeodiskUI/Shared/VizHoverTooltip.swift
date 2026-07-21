//
//  VizHoverTooltip.swift
//  Neodisk
//
//  The floating hover tooltip shared by the treemap and the sunburst: a small
//  material card that appears near the cursor and names the hovered item, its
//  size, and its share of the current drill root (free/hidden-space blocks get
//  a one-line explanation instead). The content model (VizHoverTooltipData) is
//  view-model-free so the formatting can be unit-tested; each pane builds one
//  from its own hover state and hands it to `VizHoverTooltipLayer`, which
//  positions and clamps the card within the pane.
//

import SwiftUI
import NeodiskKit
import SunburstCore

/// Content of one hover tooltip, independent of any view or the view model so
/// the primary/secondary lines can be unit-tested directly.
struct VizHoverTooltipData: Equatable {
    enum Kind: Equatable {
        case item(name: String)
        case aggregate(itemCount: Int)
        case freeSpace
        case hiddenSpace
    }

    var kind: Kind
    /// Size shown, already matching what the visualization draws (display
    /// weight, cloud-only included per the toolbar toggle).
    var sizeBytes: Int64
    /// Percent basis: the drill root's size when drilled, else the scan
    /// root's. The size line drops the percent when this is <= 0.
    var basisBytes: Int64
    /// Display name of the percent basis (drill root or scan root), used in
    /// "… of <name>".
    var basisName: String
    /// Existing category symbol for a real file/folder. Special space and
    /// aggregate blocks stay text-only.
    var itemSymbolName: String? = nil
    /// A filled cloud immediately before the size marks a genuinely dataless
    /// file. Directories with some cloud-only descendants do not wear it.
    var showsCloudGlyph = false

    /// First line: the item/aggregate name, or "Free space · <size>".
    var primaryText: String {
        switch kind {
        case .item(let name):
            return name
        case .aggregate(let itemCount):
            return String(
                format: NSLocalizedString("%@ smaller items", comment: "Hover tooltip title for a merged 'smaller items' block"),
                itemCount.formatted()
            )
        case .freeSpace:
            return String(
                format: NSLocalizedString("Free space · %@", comment: "Hover tooltip title for the free-space block; %@ is a size"),
                NeodiskFormatters.size(sizeBytes)
            )
        case .hiddenSpace:
            return String(
                format: NSLocalizedString("Hidden space · %@", comment: "Hover tooltip title for the hidden-space block; %@ is a size"),
                NeodiskFormatters.size(sizeBytes)
            )
        }
    }

    /// Second line: "<size> · <percent> of <basis>" for real items, or a
    /// one-sentence explanation for the free/hidden-space blocks.
    var secondaryText: String {
        switch kind {
        case .item, .aggregate:
            let size = NeodiskFormatters.size(sizeBytes)
            guard let percent = NeodiskFormatters.percentage(part: sizeBytes, total: basisBytes) else {
                return size
            }
            return String(
                format: NSLocalizedString("%@ · %@ of %@", comment: "Hover tooltip detail line: size, percent of the drill root, drill-root name"),
                size, percent, basisName
            )
        case .freeSpace:
            return NSLocalizedString("Space available on this volume.", comment: "Hover tooltip explanation for the free-space block")
        case .hiddenSpace:
            return NSLocalizedString("Purgeable space, local snapshots, and files the scan could not see.", comment: "Hover tooltip explanation for the hidden-space block")
        }
    }
}

extension VizHoverTooltipData {
    /// Builds the metadata for a real node. Category symbols are shared with
    /// file-result lists, but the hover card renders them without their
    /// category colors.
    init(item node: FileNodeRecord, sizeBytes: Int64, basisBytes: Int64, basisName: String) {
        self.init(
            kind: .item(name: node.name),
            sizeBytes: sizeBytes,
            basisBytes: basisBytes,
            basisName: basisName,
            itemSymbolName: FileKindClassifier.categorySymbol(
                forID: FileKindClassifier.kindID(for: node, mode: .categories)
            ),
            showsCloudGlyph: node.isDataless
        )
    }

    /// Builds the tooltip content from the shared hover state (treemap), or
    /// nil when nothing informative is hovered. Reads the model but never
    /// mutates it, so NeodiskViewModel's hover semantics stay untouched.
    @MainActor
    static func current(in model: NeodiskViewModel) -> VizHoverTooltipData? {
        let basis = model.store?.node(id: model.effectiveRootID)
        let basisBytes = basis?.displayWeight(includingCloudOnly: model.showsCloudOnlyFiles) ?? 0
        let basisName = basis?.name ?? ""

        if model.hoveredCellIsFreeSpace {
            return VizHoverTooltipData(kind: .freeSpace, sizeBytes: model.freeSpace.freeSpaceBytes ?? 0, basisBytes: basisBytes, basisName: basisName)
        }
        if model.hoveredCellIsHiddenSpace {
            return VizHoverTooltipData(kind: .hiddenSpace, sizeBytes: model.freeSpace.hiddenSpaceBytes ?? 0, basisBytes: basisBytes, basisName: basisName)
        }
        if let aggregate = model.hoveredAggregate {
            return VizHoverTooltipData(kind: .aggregate(itemCount: aggregate.itemCount), sizeBytes: aggregate.totalSize, basisBytes: basisBytes, basisName: basisName)
        }
        if let node = model.hoveredNode {
            return VizHoverTooltipData(
                item: node,
                sizeBytes: node.displayWeight(includingCloudOnly: model.showsCloudOnlyFiles),
                basisBytes: basisBytes,
                basisName: basisName
            )
        }
        return nil
    }

    /// Builds the tooltip content from a hovered sunburst segment against the
    /// chart's drill root. Uses the segment's own weight/label so the size
    /// matches what the arc draws.
    init(
        segment: SunburstSegment,
        node: FileNodeRecord?,
        basis: FileNodeRecord,
        includingCloudOnly: Bool
    ) {
        let basisBytes = basis.displayWeight(includingCloudOnly: includingCloudOnly)
        let basisName = basis.name
        if segment.isFreeSpace {
            self.init(kind: .freeSpace, sizeBytes: segment.totalSize, basisBytes: basisBytes, basisName: basisName)
        } else if segment.isHiddenSpace {
            self.init(kind: .hiddenSpace, sizeBytes: segment.totalSize, basisBytes: basisBytes, basisName: basisName)
        } else if segment.isAggregate {
            self.init(kind: .aggregate(itemCount: segment.itemCount), sizeBytes: segment.totalSize, basisBytes: basisBytes, basisName: basisName)
        } else if let node {
            self.init(item: node, sizeBytes: segment.totalSize, basisBytes: basisBytes, basisName: basisName)
        } else {
            self.init(kind: .item(name: segment.label), sizeBytes: segment.totalSize, basisBytes: basisBytes, basisName: basisName)
        }
    }
}

/// The tooltip card: two small lines in a quiet material panel. Never
/// hit-tests, so it can't intercept clicks, context menus, or Quick Look.
struct VizHoverTooltip: View {
    let data: VizHoverTooltipData

    /// Names middle-truncate past this; the card shrinks to fit shorter text.
    static let maxWidth: CGFloat = 280

    var body: some View {
        Group {
            if let symbolName = data.itemSymbolName {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        neutralSymbol(symbolName, size: 11)
                        primaryText
                    }
                    HStack(spacing: 5) {
                        if data.showsCloudGlyph {
                            neutralSymbol("cloud.fill", size: 9)
                        } else {
                            Color.clear.frame(width: 13, height: 1)
                        }
                        secondaryText
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    primaryText
                    secondaryText
                }
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
    }

    private var primaryText: some View {
        Text(data.primaryText)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var secondaryText: some View {
        Text(data.secondaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func neutralSymbol(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 13)
    }
}

/// Places a `VizHoverTooltip` near the cursor and clamps it inside the pane so
/// it never clips at an edge. Meant to sit in a pane-filling
/// `.overlay(alignment: .topLeading)`. Hidden until its size is measured so it
/// never flashes at an unclamped position (same approach as the sidebar
/// capacity bar's bubble).
struct VizHoverTooltipLayer: View {
    let data: VizHoverTooltipData
    /// Cursor position in the pane's (top-left origin) coordinate space.
    let location: CGPoint
    let paneSize: CGSize

    @State private var cardSize: CGSize = .zero
    /// The card reveals only after the cursor has rested on the visualization
    /// briefly, so sweeping across it stays quiet. The pane creates this layer
    /// when a hover starts and drops it when the hover ends, so moving between
    /// cells keeps the card up (state survives), while re-entering restarts
    /// the delay.
    @State private var revealed = false

    private static let cursorGap: CGFloat = 14
    private static let edgeInset: CGFloat = 6
    private static let revealDelay: Duration = .milliseconds(150)

    var body: some View {
        VizHoverTooltip(data: data)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: VizHoverTooltipSizeKey.self, value: proxy.size)
            })
            .offset(x: origin.x, y: origin.y)
            .opacity(cardSize == .zero || !revealed ? 0 : 1)
            .animation(.easeIn(duration: 0.12), value: revealed)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .onPreferenceChange(VizHoverTooltipSizeKey.self) { cardSize = $0 }
            .task {
                try? await Task.sleep(for: Self.revealDelay)
                revealed = true
            }
    }

    /// Top-left corner for the card: offset below-right of the cursor, flipped
    /// to the other side when it would overflow, then clamped to the pane.
    private var origin: CGPoint {
        let gap = Self.cursorGap
        let edge = Self.edgeInset
        var x = location.x + gap
        var y = location.y + gap
        if x + cardSize.width > paneSize.width - edge {
            x = location.x - gap - cardSize.width
        }
        if y + cardSize.height > paneSize.height - edge {
            y = location.y - gap - cardSize.height
        }
        x = min(max(edge, x), max(edge, paneSize.width - cardSize.width - edge))
        y = min(max(edge, y), max(edge, paneSize.height - cardSize.height - edge))
        return CGPoint(x: x, y: y)
    }
}

private struct VizHoverTooltipSizeKey: PreferenceKey {
    nonisolated static let defaultValue: CGSize = .zero

    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}
