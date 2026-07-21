//
//  SidebarTargetRow.swift
//  Neodisk
//
//  One sidebar row: icon, name, subtitle, an optional relative scan-date
//  line, and an optional capacity bar. Shared by every sidebar section.
//

import SwiftUI
import NeodiskKit

struct SidebarTargetRow: View {
    let target: ScanTarget
    let subtitle: String
    /// When a persisted snapshot exists for this location, its scan date
    /// gets its own line ("Scanned yesterday") — sharing the capacity line
    /// middle-truncated both.
    var lastScanned: Date?
    /// Reference date for the relative scan label, from the enclosing
    /// TimelineView.
    var now: Date
    /// Volume rows: the kind-colored capacity bar (empty track before any
    /// scan). Scanned cloud locations and folders: the on-this-Mac /
    /// cloud-only proportion bar.
    var bar: VolumeBarData?
    /// A background scan running for this location: its progress supersedes
    /// the capacity bar with a striped progress bar in the same slot.
    var scanProgress: ScanProgressState?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let lastScanned {
                    Text("Scanned \(DisplayFormatters.relativeDate(lastScanned, relativeTo: now))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let scanProgress {
                    SidebarScanBar(progress: scanProgress)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                        .padding(.trailing, 2)
                } else if let bar {
                    VolumeCapacityBar(data: bar)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                        .padding(.trailing, 2)
                }
            }
            Spacer(minLength: 0)
        }
        // The scan bubble rises just beyond the normal two-line row. Keep
        // that last bit inside the List cell so AppKit does not clip its top
        // edge; its anchor and spacing from the bar stay unchanged.
        .padding(.top, scanProgress != nil && lastScanned == nil ? 8 : 0)
        .padding(.vertical, 1)
    }

    private var iconName: String {
        if target.kind == .volume {
            return "internaldrive.fill"
        }
        // Remote cloud-drive account (CloudScan): distinct from the local
        // iCloud/Dropbox sync folders below.
        if target.kind == .cloud {
            return "externaldrive.badge.icloud"
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
