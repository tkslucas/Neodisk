//
//  SnapshotNoticePanel.swift
//  Neodisk
//

import SwiftUI
import NeodiskKit

/// Floating bottom-right notice shown when a location opened from its
/// snapshot instead of auto-rescanning (the last scan took long enough that
/// an unsolicited rescan would hurt). Offers the rescan the app skipped.
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
