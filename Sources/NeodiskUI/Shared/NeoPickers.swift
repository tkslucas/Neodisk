// Pickers whose titles follow the workspace text size. SwiftUI's segmented and pop-up pickers keep the system
// font whatever `.font` says, so these host the AppKit controls and set it, with the control size `neoControlSize`
// would pick.

import AppKit
import SwiftUI

extension NSControl {
    /// The workspace text scale applied to an AppKit control that `base` sizes at 100%.
    func applyNeoText(base: SwiftUI.ControlSize, scale: CGFloat) {
        let size = NSControl.ControlSize(TextScale.controlSize(base: base, scale: scale))
        let fontSize = TextScale.controlFontSize(base: base, scale: scale)
        if controlSize != size || font?.pointSize != fontSize {
            controlSize = size
            font = .systemFont(ofSize: fontSize)
            invalidateIntrinsicContentSize()
        }
    }
}

extension NSControl.ControlSize {
    init(_ size: SwiftUI.ControlSize) {
        switch size {
        case .mini: self = .mini
        case .small: self = .small
        case .large: self = .large
        case .extraLarge:
            if #available(macOS 26.0, *) { self = .extraLarge } else { self = .large }
        default: self = .regular
        }
    }
}

/// A segmented picker as wide as its titles; `options` titles are already localized.
struct NeoSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var base: ControlSize = .small
    var accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.setAccessibilityLabel(accessibilityLabel)
        control.target = context.coordinator
        control.action = #selector(Coordinator.picked(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.values = options.map(\.value)
        coordinator.select = { selection = $0 }
        control.applyNeoText(base: base, scale: context.environment.neoTextScale)
        let titles = options.map(\.title)
        if coordinator.titles != titles {
            coordinator.titles = titles
            control.segmentCount = titles.count
            for (index, title) in titles.enumerated() {
                control.setLabel(title, forSegment: index)
            }
            control.invalidateIntrinsicContentSize()
        }
        control.selectedSegment = coordinator.values.firstIndex(of: selection) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var values: [Value] = []
        var titles: [String] = []
        var select: (Value) -> Void = { _ in }

        @objc func picked(_ sender: NSSegmentedControl) {
            guard values.indices.contains(sender.selectedSegment) else { return }
            select(values[sender.selectedSegment])
        }
    }
}

/// A pop-up button picker as wide as its longest title; `contextMenu` is what a right-click shows.
struct NeoPopUpPicker<Value: Hashable>: NSViewRepresentable {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var base: ControlSize = .small
    var accessibilityLabel: String
    var contextMenu: (() -> NSMenu)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ContextMenuPopUpButton {
        let button = ContextMenuPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        return button
    }

    func updateNSView(_ button: ContextMenuPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.values = options.map(\.value)
        coordinator.select = { selection = $0 }
        button.contextMenuProvider = contextMenu
        button.applyNeoText(base: base, scale: context.environment.neoTextScale)
        let titles = options.map(\.title)
        if coordinator.titles != titles || button.menu?.font != button.font {
            coordinator.titles = titles
            button.removeAllItems()
            button.addItems(withTitles: titles)
            // The open menu matches the button's text, as AppKit's own pop-ups do.
            button.menu?.font = button.font
            button.invalidateIntrinsicContentSize()
        }
        let index = coordinator.values.firstIndex(of: selection) ?? -1
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContextMenuPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var values: [Value] = []
        var titles: [String] = []
        var select: (Value) -> Void = { _ in }

        @objc func picked(_ sender: NSPopUpButton) {
            guard values.indices.contains(sender.indexOfSelectedItem) else { return }
            select(values[sender.indexOfSelectedItem])
        }
    }
}

/// An NSPopUpButton's `menu` is its items, so its right-click menu comes from a provider instead.
final class ContextMenuPopUpButton: NSPopUpButton {
    var contextMenuProvider: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
}
