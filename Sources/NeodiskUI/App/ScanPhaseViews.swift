//
//  ScanPhaseViews.swift
//  Neodisk
//
//  The placeholder detail views for the non-workspace scan phases: the
//  welcome prompt, the scanning progress panel, the cached-snapshot restore
//  spinner, and the scan-failed message.
//

import SwiftUI
import NeodiskKit

// MARK: - Welcome

struct WelcomeView: View {
    let model: NeodiskViewModel

    private var startupVolume: ScanTarget? {
        SystemIntegration.volumeTargets().first
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Choose a Folder or Disk")
                .font(.title.weight(.semibold))

            Text("Start from the sidebar, drop a folder into the window,\nor choose a location manually.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Choose Folder…") {
                    model.chooseFolderAndScan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")

                if let startupVolume {
                    Button("Scan \(startupVolume.displayName)") {
                        model.startScan(startupVolume)
                    }
                    .buttonStyle(.bordered)
                }
            }
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
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(phaseTitle)
                .font(.headline)

            VStack(spacing: 4) {
                Text("\(progress.metrics.filesVisited.formatted()) files · \(NeodiskFormatters.size(progress.metrics.bytesDiscovered))")
                    .monospacedDigit()
                Text(progress.metrics.currentPath)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 420)
            }

            if let onStop {
                Button("Stop Scan", action: onStop)
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

/// Shown while a cached snapshot decodes with no scan running (large
/// locations skip the automatic rescan). Decode takes around a second per
/// million nodes, so this is a brief, quiet state.
struct SnapshotRestoreView: View {
    let target: ScanTarget?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Opening last scan of \(target?.displayName ?? "location")…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Failed

struct ScanFailedView: View {
    let model: NeodiskViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.headline)
            if let message = model.coordinator.scanErrorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Button("Try Again") {
                if let target = model.coordinator.selectedTarget {
                    model.startScan(target)
                }
            }
            .disabled(model.coordinator.selectedTarget == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
