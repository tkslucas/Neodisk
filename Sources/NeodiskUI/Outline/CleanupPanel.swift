// The Cleanup panel at the foot of the sidebar: a drop target for items dragged from any view, the collected
// total, and the way to review them and move them to the Trash. The review list pops over beside it.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct CleanupPanel: View {
    let model: NeodiskViewModel

    @State private var isTargeted = false
    @Environment(\.neoTextScale) private var textScale

    private var cleanup: CleanupModel { model.cleanup }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            panel
            if let notice = cleanup.notice {
                CleanupNoticeView(notice: notice, model: model)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.15), value: cleanup.notice)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .animation(.easeOut(duration: 0.12), value: cleanup.isDragInProgress)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !cleanup.isEmpty || cleanup.isMoving {
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(CleanupDropTarget(model: model, isTargeted: $isTargeted))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture {
            if !cleanup.isEmpty { cleanup.isReviewPresented = true }
        }
        .popover(isPresented: Binding(
            get: { cleanup.isReviewPresented },
            set: { cleanup.isReviewPresented = $0 }
        ), arrowEdge: .trailing) {
            CleanupReviewList(model: model)
        }
        .help(cleanup.unavailableReason ?? NSLocalizedString(
            "Drag files and folders here, or press ⌘⌫, to collect them. Nothing moves until you confirm.",
            comment: "Cleanup panel tooltip"
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Cleanup"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isTargeted ? "trash.fill" : "trash")
                .neoFont(14, weight: .medium)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .frame(width: (18 * textScale).rounded())
            VStack(alignment: .leading, spacing: 1) {
                Text("Cleanup")
                    .neoFont(12, weight: .semibold)
                Text(LocalizedStringKey(subtitle))
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !cleanup.isEmpty {
                Text(NeodiskFormatters.size(cleanup.totalSize))
                    .neoFont(12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        if isTargeted { return "Release to collect" }
        if cleanup.isMoving { return "Moving to the Trash…" }
        let count = cleanup.itemIDs.count
        if count == 0 {
            return cleanup.isDragInProgress ? "Drop here to collect" : "Drag items here to review before trashing"
        }
        return count == 1 ? "1 item" : String(format: NSLocalizedString("%lld items", comment: "Cleanup item count"), count)
    }

    @ViewBuilder
    private var actions: some View {
        if cleanup.isMoving {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                Button("Review") {
                    cleanup.isReviewPresented = true
                }
                .neoFont(.body)
                .neoControlSize(base: .small)
                Spacer(minLength: 0)
                Button("Move to Trash…") {
                    cleanup.moveAllToTrash()
                }
                .neoFont(.body)
                .neoControlSize(base: .small)
                .disabled(!cleanup.canMoveToTrash)
            }
        }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let highlighted = isTargeted || (cleanup.isDragInProgress && cleanup.isEmpty)
        return shape
            .fill(isTargeted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            .overlay(
                shape.strokeBorder(
                    highlighted ? Color.accentColor : Color.primary.opacity(cleanup.isEmpty ? 0.18 : 0.08),
                    style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: cleanup.isEmpty && !isTargeted ? [4, 3] : [])
                )
            )
    }
}

/// The line under the panel: why something wasn't collected, or how a move went.
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

/// The collected items: click one to find it in the map, remove any, then move the rest.
struct CleanupReviewList: View {
    let model: NeodiskViewModel

    private var cleanup: CleanupModel { model.cleanup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup")
                        .neoFont(13, weight: .semibold)
                    Text("Nothing moves until you confirm. Items go to the Trash, where you can put them back.")
                        .neoFont(10)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(NeodiskFormatters.size(cleanup.totalSize))
                    .neoFont(13, weight: .medium)
                    .monospacedDigit()
            }
            .padding(12)

            Divider()

            if cleanup.items.isEmpty {
                Text("Nothing collected")
                    .neoFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(cleanup.items, id: \.id) { node in
                            CleanupItemRow(node: node, failure: cleanup.failures[node.id], model: model)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 320)
            }

            Divider()

            HStack {
                Button("Clear") {
                    cleanup.clear()
                }
                .disabled(cleanup.isEmpty || cleanup.isMoving)
                Spacer()
                Button(moveTitle) {
                    cleanup.moveAllToTrash()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!cleanup.canMoveToTrash)
            }
            .neoFont(.body)
            .padding(12)
        }
        .frame(width: 400)
    }

    private var moveTitle: String {
        let count = cleanup.itemIDs.count
        return count == 1
            ? NSLocalizedString("Move 1 Item to Trash…", comment: "Cleanup review button")
            : String(format: NSLocalizedString("Move %lld Items to Trash…", comment: "Cleanup review button"), count)
    }
}

private struct CleanupItemRow: View {
    let node: FileNodeRecord
    let failure: String?
    let model: NeodiskViewModel

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            FileCategoryIcon(node: node, palette: model.vizPalette)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .neoFont(12)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((node.path as NSString).deletingLastPathComponent)
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .neoFont(10)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(NeodiskFormatters.size(node.allocatedSize))
                .neoFont(11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                model.cleanup.remove([node.id])
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .disabled(model.cleanup.isMoving)
            .help(Text("Remove from Cleanup"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.select(node.id) }
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
