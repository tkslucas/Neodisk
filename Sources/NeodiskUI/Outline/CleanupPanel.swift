// Cleanup, the sidebar's last section: a drop target for items dragged from any view, the collected items with
// their total, and the way to move them to the Trash. A hairline sets it apart; nothing moves until confirmed.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct CleanupPanel: View {
    let model: NeodiskViewModel

    @State private var isTargeted = false
    @State private var listHeight: CGFloat = 0
    @Environment(\.neoTextScale) private var textScale

    private var cleanup: CleanupModel { model.cleanup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                header
                if cleanup.isEmpty && !cleanup.isMoving {
                    hint
                } else {
                    list
                    actions
                }
                if let notice = cleanup.notice {
                    CleanupNoticeView(notice: notice, model: model)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Color.accentColor.opacity(isTargeted ? 0.14 : cleanup.isDragInProgress ? 0.06 : 0))
        .overlay(CleanupDropTarget(model: model, isTargeted: $isTargeted))
        .help(cleanup.unavailableReason ?? NSLocalizedString(
            "Drag files and folders here, or press ⌘⌫, to collect them. Nothing moves until you confirm.",
            comment: "Cleanup panel tooltip"
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Cleanup"))
        .animation(.easeOut(duration: 0.15), value: cleanup.notice)
        .animation(.easeOut(duration: 0.15), value: cleanup.itemIDs)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .animation(.easeOut(duration: 0.12), value: cleanup.isDragInProgress)
    }

    /// Styled like the list's section headers above it.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Cleanup")
                .neoFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !cleanup.isEmpty {
                Text(NeodiskFormatters.size(cleanup.totalSize))
                    .neoFont(11, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 4)
    }

    private var hint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isTargeted ? "trash.fill" : "trash")
                .foregroundStyle(isTargeted || cleanup.isDragInProgress ? Color.accentColor : .secondary)
            Text(LocalizedStringKey(hintText))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .neoFont(11)
        .padding(.horizontal, 4)
    }

    private var hintText: String {
        if isTargeted { return "Release to collect" }
        return cleanup.isDragInProgress ? "Drop here to collect" : "Drag items here to review before trashing"
    }

    /// Grows with the items up to about six rows, then scrolls.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(cleanup.items, id: \.id) { node in
                    CleanupItemRow(node: node, failure: cleanup.failures[node.id], model: model)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(listHeight, (22 * textScale).rounded() * 6.5))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if cleanup.isMoving {
                ProgressView()
                    .controlSize(.small)
                Text("Moving to the Trash…")
                    .neoFont(11)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Button("Clear") {
                    cleanup.clear()
                }
                Spacer(minLength: 0)
                Button("Move to Trash…") {
                    cleanup.moveAllToTrash()
                }
                .disabled(!cleanup.canMoveToTrash)
            }
        }
        .neoFont(.body)
        .neoControlSize(base: .small)
    }
}

/// The line under the section: why something wasn't collected, or how a move went.
private struct CleanupNoticeView: View {
    let notice: CleanupModel.Notice
    let model: NeodiskViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.text)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.kind == .moved {
                    Button("Open Trash") {
                        SystemIntegration.openTrash()
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.cleanup.dismissNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .accessibilityLabel(Text("Dismiss"))
        }
        .neoFont(10)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var symbol: String {
        switch notice.kind {
        case .info: "info.circle"
        case .refused: "hand.raised"
        case .moved: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: .secondary
        case .refused: .orange
        case .moved: .green
        case .failed: .red
        }
    }
}

/// One collected item: click finds it in the map, double-click shows it in Finder; hovering swaps its size for a
/// remove button.
private struct CleanupItemRow: View {
    let node: FileNodeRecord
    let failure: String?
    let model: NeodiskViewModel

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FileCategoryIcon(node: node, palette: model.vizPalette)
                .frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .neoFont(12)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failure {
                    Text(failure)
                        .neoFont(10)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                Text(NeodiskFormatters.size(node.allocatedSize))
                    .neoFont(11)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 0 : 1)
                Button {
                    model.cleanup.remove([node.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .neoFont(12)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.cleanup.isMoving)
                .help(Text("Remove from Cleanup"))
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.select(node.id) }
        // As in the file list: double-click shows the item in Finder.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard model.supportsFileActions(node) else { return }
            model.select(node.id)
            model.reveal(node)
        })
        .contextMenu {
            Button("Reveal in Finder") {
                SystemIntegration.reveal(URL(filePath: node.path))
            }
            Divider()
            Button("Remove from Cleanup") {
                model.cleanup.remove([node.id])
            }
            .disabled(model.cleanup.isMoving)
        }
        .help(node.path)
    }
}

// MARK: - Drop target

/// AppKit drop view over the panel: a private pasteboard type needs no declared UTType, and only payloads from
/// the tree on screen are accepted.
private struct CleanupDropTarget: NSViewRepresentable {
    let model: NeodiskViewModel
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes([.neodiskNodes])
        update(view)
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        update(view)
    }

    private func update(_ view: DropView) {
        view.acceptedIDs = { [weak model] pasteboard in
            guard let model, model.cleanup.unavailableReason == nil, !model.cleanup.isMoving else { return nil }
            return NodeDragPayload.nodeIDs(on: pasteboard, snapshotID: model.coordinator.snapshot?.id)
        }
        view.onDrop = { [weak model] ids in model?.cleanup.add(ids: ids) }
        view.onTargetedChange = { targeted in
            if isTargeted != targeted { isTargeted = targeted }
        }
    }

    final class DropView: NSView {
        var acceptedIDs: (NSPasteboard) -> [String]? = { _ in nil }
        var onDrop: ([String]) -> Void = { _ in }
        var onTargetedChange: (Bool) -> Void = { _ in }

        // Clicks go through to the SwiftUI panel underneath; only drags stop here.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard acceptedIDs(sender.draggingPasteboard) != nil else { return [] }
            onTargetedChange(true)
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            acceptedIDs(sender.draggingPasteboard) != nil ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            onTargetedChange(false)
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            onTargetedChange(false)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onTargetedChange(false)
            guard let ids = acceptedIDs(sender.draggingPasteboard) else { return false }
            onDrop(ids)
            return true
        }
    }
}
