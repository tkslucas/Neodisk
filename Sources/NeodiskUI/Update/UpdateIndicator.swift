//
//  UpdateIndicator.swift
//  Neodisk
//
//  Unobtrusive update status in the window's top-right toolbar area, like
//  Ghostty's update pill: invisible while idle, a small spinner-or-symbol
//  plus status text while Sparkle works, and a popover with the one or two
//  relevant actions. This is a transient status readout, not a persistent
//  toolbar button, so appearing/disappearing is intentional.
//

import SwiftUI

struct UpdateIndicator: View {
    @ObservedObject var viewModel: UpdateViewModel

    @State private var showPopover = false
    /// Auto-dismisses the quiet "You're up to date." confirmation.
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        if !viewModel.state.isIdle {
            Button {
                if case .upToDate(let acknowledge) = viewModel.state {
                    viewModel.state = .idle
                    acknowledge()
                } else {
                    showPopover.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    if viewModel.state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else if let symbol = viewModel.state.symbolName {
                        Image(systemName: symbol)
                            .foregroundStyle(symbolColor)
                    }
                    Text(verbatim: viewModel.state.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(viewModel.state.title)
            .accessibilityLabel(Text(verbatim: viewModel.state.title))
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                UpdatePopover(viewModel: viewModel)
            }
            .onChange(of: viewModel.state.isIdle) { _, isIdle in
                if isIdle { showPopover = false }
            }
            .task(id: upToDateToken) {
                // Let the confirmation linger briefly, then acknowledge it.
                guard case .upToDate(let acknowledge) = viewModel.state else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, case .upToDate = viewModel.state else { return }
                viewModel.state = .idle
                acknowledge()
            }
        }
    }

    /// Changes when the state enters .upToDate so the auto-dismiss task restarts.
    private var upToDateToken: Bool {
        if case .upToDate = viewModel.state { return true }
        return false
    }

    private var symbolColor: Color {
        switch viewModel.state {
        case .failed: return .orange
        case .upToDate: return .green
        default: return .accentColor
        }
    }
}

/// Compact action sheet for the current update state.
private struct UpdatePopover: View {
    @ObservedObject var viewModel: UpdateViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.state {
            case .idle:
                EmptyView()

            case .checking(let cancel):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for Updates…")
                }
                trailingButtons {
                    Button("Cancel") {
                        cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }

            case .available(let version, let install, let dismissUpdate):
                Text(String(
                    format: NSLocalizedString(
                        "Version %@ is available.",
                        comment: "Update popover, new version line"),
                    version
                ))
                .fontWeight(.semibold)
                trailingButtons {
                    Button("Later") {
                        dismissUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Install Update") {
                        install()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }

            case .downloading:
                progressRow(label: "Downloading Update…")
                if case .downloading(_, _, let cancel) = viewModel.state {
                    trailingButtons {
                        Button("Cancel") {
                            cancel()
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }

            case .extracting:
                progressRow(label: "Preparing Update…")

            case .readyToInstall(let install, let dismissUpdate):
                Text("Ready to Install")
                    .fontWeight(.semibold)
                trailingButtons {
                    Button("Later") {
                        dismissUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Install and Relaunch") {
                        install()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }

            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing Update…")
                }

            case .upToDate(let acknowledge):
                Text("You're up to date.")
                trailingButtons {
                    Button("OK") {
                        viewModel.state = .idle
                        acknowledge()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .failed(let message, let dismissError):
                Text("Update Error")
                    .fontWeight(.semibold)
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                trailingButtons {
                    Button("OK") {
                        dismissError()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    @ViewBuilder
    private func progressRow(label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            if let fraction = viewModel.state.progressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    @ViewBuilder
    private func trailingButtons(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
        .controlSize(.small)
    }
}
