// One sidebar row: icon, the name with its size trailing, when it was scanned, and an optional bar. The full path
// is the tooltip. Shared by every sidebar section.

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
    var tooltip: String
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

            VStack(alignment: .leading, spacing: (1 * textScale).rounded()) {
                HStack(alignment: .firstTextBaseline, spacing: (6 * textScale).rounded()) {
                    // Explicit: the list's default dims names in an inactive window, so they'd all read disabled.
                    Text(target.displayName)
                        .neoFont(13, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let size {
                        Text(size)
                            .neoFont(10.5)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.trailing, (2 * textScale).rounded())
                    }
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
        .help(tooltip)
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
