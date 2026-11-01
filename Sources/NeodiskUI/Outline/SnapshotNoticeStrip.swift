import SwiftUI
import NeodiskKit
import NeodiskAppModel

/// The strip under the map when a location opened from its snapshot without the rescan; its age reads the same
/// date as the sidebar row, on the same minute timeline.
struct SnapshotNoticeStrip: View {
    let model: NeodiskViewModel
    let notice: ScanSessionModel.SnapshotNotice

    private var scanDate: Date {
        model.session.cachedScanInfo[notice.targetID]?.lastScanDate ?? notice.scanDate
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            TimelineView(.everyMinute) { context in
                let age = Text("Showing scan from \(DisplayFormatters.relativeDate(scanDate, relativeTo: context.date))")
                    .fontWeight(.medium)
                // The last scan's duration goes first when the strip runs out of room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        age
                        if let duration = notice.lastScanDuration {
                            Text("Rescanning took about \(DisplayFormatters.roughDuration(duration)) last time.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    age
                }
            }
            Spacer(minLength: 4)
            Button {
                model.rescan()
            } label: {
                Text("Rescan Now").neoFont(11)
            }
            .neoControlSize(base: .small)
            Button {
                model.session.dismissSnapshotNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Keep the snapshot and dismiss")
        }
        .lineLimit(1)
        .neoFont(11)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
