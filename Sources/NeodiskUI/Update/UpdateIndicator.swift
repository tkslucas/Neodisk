//
//  UpdateIndicator.swift
//  Neodisk
//
//  Update status pill in the window toolbar, between the center view picker
//  and the trailing buttons. Invisible while idle; once a check runs it
//  persists until the user acts on it. The pill body is the primary action
//  (install when an update exists, dismiss when up to date) and the small
//  x dismisses or cancels, so no popover is needed.
//

import SwiftUI

struct UpdateIndicator: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        if !viewModel.state.isIdle {
            HStack(spacing: 2) {
                if let action = primaryAction {
                    Button(action: action) { pillLabel }
                        .buttonStyle(.plain)
                } else {
                    pillLabel
                }

                if let dismiss = dismissAction {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss"))
                    .padding(.trailing, 4)
                } else {
                    Spacer().frame(width: 8)
                }
            }
            .background(Capsule().fill(.quaternary.opacity(0.6)))
            .help(helpText)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: viewModel.state.title))
        }
    }

    private var pillLabel: some View {
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
        .padding(.leading, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// What clicking the pill body does. Progress states have no primary
    /// action; the x is the only control there.
    private var primaryAction: (() -> Void)? {
        switch viewModel.state {
        case .available(_, let install, _):
            return install
        case .readyToInstall(let install, _):
            return install
        case .upToDate:
            return { viewModel.state = .idle }
        case .failed(_, let dismiss):
            return dismiss
        default:
            return nil
        }
    }

    /// What the small x does: dismiss a result, cancel work in flight.
    /// Extraction and install cannot be cancelled, so no x there.
    private var dismissAction: (() -> Void)? {
        switch viewModel.state {
        case .idle, .extracting, .installing:
            return nil
        case .checking(let cancel):
            return cancel
        case .available(_, _, let dismiss):
            return dismiss
        case .downloading(_, _, let cancel):
            return cancel
        case .readyToInstall(_, let dismiss):
            return dismiss
        case .upToDate:
            return { viewModel.state = .idle }
        case .failed(_, let dismiss):
            return dismiss
        }
    }

    private var helpText: String {
        switch viewModel.state {
        case .available(let version, _, _):
            return String(
                format: NSLocalizedString(
                    "Version %@ is available.",
                    comment: "Update pill tooltip, new version line"),
                version
            )
        case .readyToInstall:
            return NSLocalizedString(
                "Install and Relaunch",
                comment: "Update pill tooltip, update downloaded and waiting")
        case .failed(let message, _):
            return message
        default:
            return viewModel.state.title
        }
    }

    private var symbolColor: Color {
        switch viewModel.state {
        case .failed: return .orange
        case .upToDate: return .green
        default: return .accentColor
        }
    }
}
