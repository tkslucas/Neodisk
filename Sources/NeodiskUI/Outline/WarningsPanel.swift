//
//  WarningsPanel.swift
//  Neodisk
//
//  Floating bottom-right panel listing scan warnings (unreadable folders,
//  filesystem errors). Each warning can be dismissed; the panel disappears
//  once every warning is dismissed.
//

import SwiftUI
import NeodiskKit

/// Floating notice shown when a location opened from its snapshot instead
/// of auto-rescanning (the last scan took long enough that an unsolicited
/// rescan would hurt). Offers the rescan the app skipped; stacks above the
/// warnings panel.
struct SnapshotNoticePanel: View {
    let model: NeodiskViewModel

    var body: some View {
        if let notice = model.session.snapshotNotice {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Showing scan from \(DisplayFormatters.relativeDate(notice.scanDate))")
                            .font(.system(size: 12, weight: .semibold))
                        if let duration = notice.lastScanDuration {
                            Text("Rescanning took about \(DisplayFormatters.roughDuration(duration)) last time.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        model.session.snapshotNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Keep the snapshot and dismiss")
                }

                Button("Rescan Now") {
                    model.rescan()
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

struct WarningsPanel: View {
    let model: NeodiskViewModel

    var body: some View {
        let warnings = model.warnings.visible
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Warnings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.warnings.dismissAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss all warnings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(warnings) { warning in
                            WarningRow(warning: warning) {
                                model.warnings.dismiss(warning.id)
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

private struct WarningRow: View {
    let warning: ScanWarning
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning.category == .permissionDenied
                ? "hand.raised.fill"
                : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(warning.path)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(warning.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.35)
            .help("Dismiss this warning")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
