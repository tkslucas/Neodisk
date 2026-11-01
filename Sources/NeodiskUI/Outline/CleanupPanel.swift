// Cleanup, the sidebar's last section: a drop target for items dragged from any view, the collected items with
// their total, and the way to move them to the Trash. A hairline sets it apart; nothing moves until confirmed.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct CleanupPanel: View {
    let model: NeodiskViewModel

    @State private var isTargeted = false
    @Environment(\.neoTextScale) private var textScale

    private var cleanup: CleanupModel { model.cleanup }

    /// One line of a row; rows with a failure under the name grow past it.
    private var rowHeight: CGFloat { (22 * textScale).rounded() }

    /// A drag the panel would take: only while items can be collected.
    private var isInviting: Bool { cleanup.isDragInProgress && cleanup.unavailableReason == nil }

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
        .background(Color.accentColor.opacity(isTargeted ? 0.14 : isInviting ? 0.06 : 0))
        .overlay(CleanupDropTarget(model: model, isTargeted: $isTargeted))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Cleanup"))
        .animation(.easeOut(duration: 0.15), value: cleanup.notice)
        .animation(.easeOut(duration: 0.15), value: cleanup.itemIDs)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .animation(.easeOut(duration: 0.12), value: isInviting)
    }

    /// Styled like the list's section headers above it.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Cleanup")
                .neoFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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

    /// How to collect, or why nothing can be collected now.
    private var hint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isTargeted ? "trash.fill" : "trash")
                .foregroundStyle(isTargeted || isInviting ? Color.accentColor : .secondary)
                .frame(width: (16 * textScale).rounded())
            Group {
                if let reason = cleanup.unavailableReason {
                    Text(reason)
                } else {
                    Text(LocalizedStringKey(hintText))
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .neoFont(11)
        .padding(.horizontal, 4)
        .help(cleanup.unavailableReason == nil ? NSLocalizedString(
            "Drag files and folders here, or press ⌘⌫, to collect them. Nothing moves until you confirm.",
            comment: "Cleanup panel tooltip"
        ) : "")
    }

    private var hintText: String {
        if isTargeted { return "Release to collect" }
        return isInviting ? "Drop here to collect" : "Drag items here to review before trashing"
    }

    /// Grows with the items up to six and a half rows, then scrolls: the half row says there's more.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(cleanup.items, id: \.id) { node in
                    CleanupItemRow(
                        node: node,
                        failure: cleanup.failures[node.id],
                        isMoving: cleanup.mark(for: node.id) == .moving,
                        isSelected: model.selectedNodeID == node.id,
                        minHeight: rowHeight,
                        model: model
                    )
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: rowHeight * 6.5)
        .fixedSize(horizontal: false, vertical: true)
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
                // Side by side, or stacked like an alert's buttons where a translation doesn't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        clearButton.fixedSize()
                        Spacer(minLength: 0)
                        moveButton.fixedSize()
                    }
                    VStack(spacing: 6) {
                        moveButton
                        clearButton
                    }
                }
            }
        }
        .neoFont(.body)
        .neoControlSize(base: .small)
    }

    /// Their labels fill the width they're given: the stacked buttons span the panel.
    private var clearButton: some View {
        Button {
            cleanup.clear()
        } label: {
            Text("Clear").frame(maxWidth: .infinity)
        }
    }

    private var moveButton: some View {
        Button {
            cleanup.moveAllToTrash()
        } label: {
            Text("Move to Trash…").frame(maxWidth: .infinity)
        }
        .disabled(!cleanup.canMoveToTrash)
    }
}

/// The line under the section: why something wasn't collected, or how a move went.
private struct CleanupNoticeView: View {
    let notice: CleanupModel.Notice
    let model: NeodiskViewModel

    @Environment(\.neoTextScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: (16 * textScale).rounded())
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.text)
                    .foregroundStyle(.secondary)
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
        .neoFont(11)
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
/// remove button. The item selected in the map is highlighted, so ⌘⌫ visibly takes it out.
private struct CleanupItemRow: View {
    let node: FileNodeRecord
    let failure: String?
    let isMoving: Bool
    let isSelected: Bool
    let minHeight: CGFloat
    let model: NeodiskViewModel

    @State private var isHovered = false
    @Environment(\.neoTextScale) private var textScale

    /// A hard link or clone counted under its other name: moving this one alone frees nothing, and "Zero bytes"
    /// would read as a mistake.
    private var isShared: Bool {
        !node.isDirectory && node.allocatedSize == 0 && node.logicalSize > 0
            && (node.linkCount > 1 || node.cloneInfo != nil)
    }

    private var sizeText: String {
        isShared
            ? NSLocalizedString("Shared", comment: "Cleanup item size: a hard link or clone whose space is counted elsewhere")
            : NeodiskFormatters.size(node.allocatedSize)
    }

    var body: some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : isHovered ? 0.05 : 0))
            )
            .opacity(isMoving ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { model.select(node.id) }
            // As in the file list: double-click shows the item in Finder.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard model.supportsFileActions(node) else { return }
                model.select(node.id)
                model.reveal(node)
            })
            .contextMenu { menu }
            .help(isShared ? node.path + "\n" + NSLocalizedString(
                "Shares its storage with another file (a hard link or clone), so moving it alone frees no space.",
                comment: "Cleanup item tooltip"
            ) : node.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(node.name), \(sizeText)"))
            .accessibilityValue(failure.map { Text($0) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(node.id) }
            .accessibilityAction(named: Text("Reveal in Finder")) { model.reveal(node) }
            .accessibilityAction(named: Text("Remove from Cleanup")) { model.cleanup.remove([node.id]) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FileCategoryIcon(node: node, palette: model.vizPalette)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(node.name)
                    .neoFont(12)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                trailing
            }
            // Under the name, as wide as the row.
            if let failure {
                Text(failure)
                    .neoFont(10)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, (16 * textScale).rounded() + 6)
            }
        }
    }

    /// The size, or the remove button while the pointer is over the row.
    @ViewBuilder
    private var trailing: some View {
        if isHovered && !isMoving {
            Button {
                model.cleanup.remove([node.id])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .neoFont(12)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Text("Remove from Cleanup"))
        } else {
            Text(sizeText)
                .neoFont(11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The file lists' menu, with Remove in place of Add.
    @ViewBuilder
    private var menu: some View {
        if model.supportsFileActions(node) {
            Button("Reveal in Finder") { model.reveal(node) }
            Button("Open") { model.open(node) }
            Button("Copy Path") { model.copyPath(node) }
            Divider()
        }
        Button("Remove from Cleanup") {
            model.cleanup.remove([node.id])
        }
        .disabled(isMoving)
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
