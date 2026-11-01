import SwiftUI
import NeodiskKit
import NeodiskAppModel

// MARK: - Welcome

struct WelcomeView: View {
    let model: NeodiskViewModel

    private var startupVolume: ScanTarget? {
        SystemIntegration.volumeTargets().first
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .neoFont(48, weight: .light)
                .foregroundStyle(.secondary)

            Text("Choose a Folder or Disk")
                .neoFont(22, weight: .semibold)

            Text("Pick a location in the sidebar or drop a folder here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // The default button ends the row; the menu's Add Folder… keeps ⌘O.
            HStack(spacing: 10) {
                if let startupVolume {
                    Button {
                        model.startScan(startupVolume)
                    } label: {
                        Text("Scan \(startupVolume.displayName)").neoFont(.body)
                    }
                }

                Button {
                    model.chooseFolderAndScan()
                } label: {
                    Text("Choose Folder…").neoFont(.body)
                }
                .keyboardShortcut(.defaultAction)
            }
            .neoControlSize()
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scanning

struct ScanProgressView: View {
    let model: NeodiskViewModel

    var body: some View {
        ScanProgressContent(
            progress: model.coordinator.progress,
            targetName: model.coordinator.selectedTarget?.displayName ?? "",
            onStop: { model.stopScan() }
        )
    }
}

private struct ScanProgressContent: View {
    @ObservedObject var progress: ScanProgressState
    let targetName: String
    var onStop: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            StripedProgressBar(value: progress.metrics.progressFraction)
                .frame(width: 340)

            Text(progress.metrics.progressFraction.formatted(.percent.precision(.fractionLength(0))))
                .neoFont(11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(phaseTitle)
                .neoFont(.headline)

            VStack(spacing: 4) {
                Text(AppStrings.plural(
                    progress.metrics.filesVisited, one: "%@ file · %@", other: "%@ files · %@",
                    progress.metrics.filesVisited.formatted(), NeodiskFormatters.size(progress.metrics.bytesDiscovered)
                ))
                    .monospacedDigit()
                Text(progress.metrics.currentPath)
                    .foregroundStyle(.secondary)
                    .neoFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 420)
            }

            if let onStop {
                Button(action: onStop) { Text("Stop Scan").neoFont(.body) }
                    .neoControlSize()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phaseTitle: LocalizedStringKey {
        if progress.metrics.isMergingChanges {
            return "Applying changes…"
        }
        if progress.metrics.isFinalizing {
            return "Assembling results for \(targetName)…"
        }
        return "Scanning \(targetName)…"
    }
}

// MARK: - Snapshot restore

/// Large locations skip the automatic rescan. Decode takes about a second per million nodes.
struct SnapshotRestoreView: View {
    let target: ScanTarget?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .neoControlSize(base: .small)
            Text("Opening last scan of \(target?.displayName ?? "location")…")
                .neoFont(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Failed

struct ScanFailedView: View {
    let model: NeodiskViewModel

    var body: some View {
        // Laid out like the empty state: one glyph, a title, a line of detail, the default button.
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .neoFont(48, weight: .light)
                .foregroundStyle(.orange)
            Text("Scan Failed")
                .neoFont(22, weight: .semibold)
            if let message = model.coordinator.scanErrorMessage {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Button {
                if let target = model.coordinator.selectedTarget {
                    model.startScan(target)
                }
            } label: {
                Text("Try Again").neoFont(.body)
            }
            .keyboardShortcut(.defaultAction)
            .neoControlSize()
            .padding(.top, 6)
            .disabled(model.coordinator.selectedTarget == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
