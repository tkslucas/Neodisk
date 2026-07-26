//
//  OutlineRowMetrics.swift
//  Neodisk
//
//  Layout constants of the old SwiftUI List rows, measured pixel-for-pixel
//  from it, isolated here so the SwiftUI row content and the AppKit table
//  both mirror the same numbers.
//

import AppKit
import NeodiskKit

// MARK: - Shared row metrics

/// Layout constants of the old SwiftUI List rows, measured pixel-for-pixel
/// from it: both the SwiftUI row content and the AppKit table below mirror
/// them so the everything-fits case is indistinguishable from the List.
@MainActor
enum OutlineRowMetrics {
    /// The workspace text scale (see TextScale), pushed here by the view
    /// model: this enum is read from AppKit table code with no SwiftUI
    /// environment to draw on. Everything sized around text below derives
    /// from it; the measurement cache holds widths for the current scale
    /// only, so it clears on every change.
    static var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            widthCache.removeAllObjects()
        }
    }

    /// Row text size at 100%.
    static let baseFontSize: CGFloat = 12
    static var fontSize: CGFloat { baseFontSize * scale }
    /// Vertical pitch of a List row at defaultMinListRowHeight 20: the text
    /// plus a fixed 11pt of air, so larger text stays as dense as it can.
    static var rowHeight: CGFloat { ceil(fontSize) + 11 }
    /// Indentation per outline depth level.
    static var indentPerDepth: CGFloat { (14 * scale).rounded() }
    /// Fixed-width slots the name section reserves ahead of the name, and
    /// the glyph sizes that sit in them. Mirrored by OutlineNameSection —
    /// they live here so the measurement below and the row that renders can
    /// never disagree.
    static var chevronSlotWidth: CGFloat { (14 * scale).rounded() }
    static var iconSlotWidth: CGFloat { (16 * scale).rounded() }
    static var chevronFontSize: CGFloat { 9 * scale }
    static var iconFontSize: CGFloat { 11 * scale }
    /// Spacing between the name section's elements.
    static let rowSpacing: CGFloat = 4

    /// List's leading/trailing content inset inside the pane.
    static let contentInset: CGFloat = 16
    /// List's selection is a rounded rect inset from the pane edges.
    static let selectionInset: CGFloat = 10
    static let selectionRadius: CGFloat = 5
    /// List's breathing room above the first and below the last row.
    static let verticalContentInset: CGFloat = 10
    /// Opaque margin ahead of the pinned trailing cluster: long names clip
    /// hard against it, mirroring the List's 8pt minimum name↔size gap.
    static let clusterLeadingMargin: CGFloat = 8

    private static var nameFont: NSFont { .systemFont(ofSize: fontSize) }
    private static var sizeFont: NSFont {
        .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
    }
    private static let widthCache = NSCache<NSString, NSNumber>()

    /// Natural (untruncated) width of the widest row: the column grows to
    /// this, at which point the horizontal scroller engages. Mirrors the
    /// HStack in OutlineNameSection: inset + indent + the chevron and icon
    /// slots, four inter-element gaps, then the name, an 8pt minimum gap,
    /// and the trailing cluster at its own inset.
    static func contentWidth(
        for rows: [NeodiskViewModel.OutlineRow], baseline: ScanSizeBaseline?,
        includeCloudOnly: Bool
    ) -> CGFloat {
        let leading = chevronSlotWidth + iconSlotWidth + 4 * rowSpacing
        var maxWidth: CGFloat = 0
        for row in rows {
            var width = contentInset + CGFloat(row.depth) * indentPerDepth + leading
            width += cachedWidth(of: row.node.name, font: nameFont, cachePrefix: "n:")
            width += 8 + clusterWidth(for: row, baseline: baseline, includeCloudOnly: includeCloudOnly)
                + contentInset
            maxWidth = max(maxWidth, width)
        }
        return maxWidth.rounded(.up)
    }

    static func clusterWidth(
        for row: NeodiskViewModel.OutlineRow, baseline: ScanSizeBaseline?,
        includeCloudOnly: Bool
    ) -> CGFloat {
        var width = cachedWidth(
            of: NeodiskFormatters.size(row.node.displayWeight(includingCloudOnly: includeCloudOnly)),
            font: sizeFont,
            cachePrefix: "s:"
        )
        if includeCloudOnly {
            // FileSizeLabel reserves its trailing glyph slot on every row.
            width += FileSizeLabel.glyphSlotWidth(scale: scale) + 3
        }
        if let baseline {
            width += cachedWidth(
                of: NeodiskFormatters.sizeDelta(baseline.sizeDelta(for: row.node)),
                font: sizeFont,
                cachePrefix: "s:"
            ) + 4
        }
        return width
    }

    private static func cachedWidth(of text: String, font: NSFont, cachePrefix: String) -> CGFloat {
        let key = (cachePrefix + text) as NSString
        if let cached = widthCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        widthCache.setObject(NSNumber(value: width), forKey: key)
        return width
    }
}

/// Reveals an outline row without changing horizontal scroll. AppKit's table
/// header overlays the top of its clip view, so callers with a header supply
/// that covered height instead of treating the whole clip bounds as visible.
@MainActor
func scrollOutlineRowVertically(
    _ rowRect: NSRect,
    in scrollView: NSScrollView,
    topOcclusion: CGFloat = 0
) {
    let clip = scrollView.contentView
    let occlusion = min(max(topOcclusion, 0), clip.bounds.height)
    let visibleTop = clip.bounds.minY + occlusion
    var origin = clip.bounds.origin

    if rowRect.minY < visibleTop {
        origin.y = rowRect.minY - occlusion
    } else if rowRect.maxY > clip.bounds.maxY {
        origin.y = rowRect.maxY - clip.bounds.height
    } else {
        return
    }

    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
}
