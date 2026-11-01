// One sidebar row: icon, the name with its size trailing, a volume's usage, when it was scanned, and an optional
// bar. The full path is the tooltip. Shared by every sidebar section.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct SidebarTargetRow: View {
    @Environment(\.neoTextScale) private var textScale
    @Environment(\.controlActiveState) private var activeState

    let target: ScanTarget
    /// A volume's free space or a folder's scanned size; nil before a folder's first scan.
    var size: String?
    var lastScanned: Date?
    /// Reference date for the relative scan label, from the enclosing TimelineView.
    var now: Date
    /// The list's selection fill is the accent in a key window, where an accent glyph would vanish.
    var isSelected = false
    /// A volume's "used of capacity" line.
    var usage: String?
    /// Volumes: the kind-colored capacity bar (an empty track before any scan). Scanned cloud locations and
    /// folders: the on-this-Mac / cloud-only or kinds bar.
    var bar: VolumeBarData?
    /// A background scan running for this location: its striped progress bar takes the bar's slot.
    var scanProgress: ScanProgressState?
    /// Lift the bars' bubbles into SidebarPane's overlay, above List cells.
    var onScanBarFrameChange: (String, CGRect?) -> Void = { _, _ in }
    var onScanBarHover: (String, Bool) -> Void = { _, _ in }
    var onCapacityBubble: (VolumeBarBubble) -> Void = { _ in }

    var body: some View {
        // The icon slot and the gap after it follow the glyph, or a larger text size crowds the name.
        HStack(spacing: (8 * textScale).rounded()) {
            Image(systemName: iconName)
                .neoFont(15)
                .foregroundStyle(iconStyle)
                .frame(width: (22 * textScale).rounded())

            VStack(alignment: .leading, spacing: lineSpacing) {
                if let usage {
                    // The name never gives way to the numbers: free moves under it when both don't fit.
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: lineSpacing) {
                            nameLine(trailing: size)
                            detail(usage)
                        }
                        VStack(alignment: .leading, spacing: lineSpacing) {
                            nameLine(trailing: nil)
                            detail([usage, size].compactMap { $0 }.joined(separator: " · "))
                        }
                        VStack(alignment: .leading, spacing: lineSpacing) {
                            nameLine(trailing: nil)
                            detail(usage)
                            if let size { detail(size) }
                        }
                    }
                } else {
                    nameLine(trailing: size)
                }
                if let scanned = SidebarRowText.scanned(lastScanned, now: now) {
                    Text(scanned)
                        .neoFont(10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let scanProgress {
                    SidebarScanBar(
                        targetID: target.id,
                        progress: scanProgress,
                        onFrameChange: onScanBarFrameChange,
                        onHover: onScanBarHover
                    )
                    .padding(.top, 3)
                    .padding(.bottom, 1)
                    .padding(.trailing, 2)
                } else if let bar {
                    VolumeCapacityBar(data: bar, ownerID: target.id, onBubble: onCapacityBubble)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                        .padding(.trailing, 2)
                }
            }
        }
        .padding(.vertical, 1)
        .neoHelp(target.id)
    }

    private var lineSpacing: CGFloat { (1 * textScale).rounded() }

    private func nameLine(trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: (6 * textScale).rounded()) {
            // Explicit: the list's default dims names in an inactive window, so they'd all read disabled.
            Text(target.displayName)
                .neoFont(13, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .neoFont(10.5)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, (2 * textScale).rounded())
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .neoFont(10.5)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Accent glyphs in a key window, white on its selection; gray when the window isn't key, as source lists do.
    private var iconStyle: AnyShapeStyle {
        guard activeState != .inactive else { return AnyShapeStyle(.secondary) }
        return isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }

    private var iconName: String {
        if target.kind == .volume {
            return "internaldrive.fill"
        }
        if CloudLocationDetector.isCloudPath(target.id) || target.displayName == "Dropbox" {
            return target.displayName.hasPrefix("iCloud") ? "icloud.fill" : "cloud.fill"
        }
        switch target.displayName {
        case "Home", NSUserName():
            return "house.fill"
        case "Desktop":
            return "menubar.dock.rectangle"
        case "Documents":
            return "doc.on.doc.fill"
        case "Downloads":
            return "arrow.down.circle.fill"
        case "Library":
            return "books.vertical.fill"
        case "Applications":
            return "square.grid.2x2.fill"
        default:
            return "folder.fill"
        }
    }
}
