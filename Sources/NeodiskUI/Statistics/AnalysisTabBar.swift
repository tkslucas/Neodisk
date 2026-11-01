// The statistics tabs: a segmented control while every shown tab fits its full title, else a pop-up of them, so
// titles never truncate at any pane width, language or text size. Dragging a segment moves its tab; right-clicking
// one (or the pop-up) moves it left or right and shows or hides tabs.

import AppKit
import SwiftUI
import NeodiskAppModel

extension AnalysisTab {
    var localizedTitle: String { NSLocalizedString(title, comment: "Statistics tab") }
}

struct AnalysisTabBar: View {
    let model: NeodiskViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            AnalysisSegmentedControl(model: model)
            Picker("Statistics", selection: Binding(get: { model.analysisTab }, set: { model.analysisTab = $0 })) {
                ForEach(model.analysisTabs.visible) { tab in
                    Text(LocalizedStringKey(tab.title)).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { AnalysisTabsMenuItems(model: model, moving: model.analysisTab) }
        }
        .neoControlSize(base: .small)
        .padding(.horizontal, StatsListMetrics.inset)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// Which tabs show, for the pane's SwiftUI menus (its headers and empty space) and View > Statistics Tabs; the
/// pop-up's menu also moves its tab.
struct AnalysisTabsMenuItems: View {
    let model: NeodiskViewModel
    var moving: AnalysisTab?

    var body: some View {
        let layout = model.analysisTabs
        if let moving, let index = layout.visible.firstIndex(of: moving) {
            Button("Move Left") { model.moveAnalysisTab(moving, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { model.moveAnalysisTab(moving, to: index + 1) }
                .disabled(index == layout.visible.count - 1)
            Divider()
        }
        ForEach(layout.order) { tab in
            Toggle(LocalizedStringKey(tab.title), isOn: Binding(
                get: { !layout.isHidden(tab) },
                set: { model.setAnalysisTab(tab, shown: $0) }
            ))
            .disabled(!layout.isHidden(tab) && !layout.canHide(tab))
        }
        Divider()
        Button("Reset Tabs") { model.setAnalysisTabs(ItemLayout()) }
            .disabled(layout.isStandard)
    }
}

extension NeodiskViewModel {
    func setAnalysisTab(_ tab: AnalysisTab, shown: Bool) {
        var layout = analysisTabs
        layout.setHidden(tab, !shown)
        setAnalysisTabs(layout)
    }

    /// Moves a shown tab to `index` among the shown ones.
    func moveAnalysisTab(_ tab: AnalysisTab, to index: Int) {
        var visible = analysisTabs.visible
        guard let from = visible.firstIndex(of: tab), visible.indices.contains(index), from != index else { return }
        visible.insert(visible.remove(at: from), at: index)
        var layout = analysisTabs
        layout.setVisibleOrder(visible)
        setAnalysisTabs(layout)
    }
}

extension NSMenu {
    /// AppKit's copy of AnalysisTabsMenuItems, for menus AppKit builds: the control's and the lists' empty space.
    @MainActor func addAnalysisTabItems(model: NeodiskViewModel) {
        let layout = model.analysisTabs
        for tab in layout.order {
            let item = ClosureMenuItem(title: tab.localizedTitle) {
                model.setAnalysisTab(tab, shown: model.analysisTabs.isHidden(tab))
            }
            item.state = layout.isHidden(tab) ? .off : .on
            item.isEnabled = layout.isHidden(tab) || layout.canHide(tab)
            addItem(item)
        }
        addItem(.separator())
        let reset = ClosureMenuItem(title: NSLocalizedString("Reset Tabs", comment: "Statistics tab menu")) {
            model.setAnalysisTabs(ItemLayout())
        }
        reset.isEnabled = !layout.isStandard
        addItem(reset)
    }
}

/// Segments as wide as their titles, not all as wide as the widest, so the control fits the narrowest pane it can;
/// it stretches proportionally to fill the rest.
private struct AnalysisSegmentedControl: NSViewRepresentable {
    let model: NeodiskViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TabSegmentedControl {
        let control = TabSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillProportionally
        control.setAccessibilityLabel(NSLocalizedString("Statistics", comment: "Statistics tabs"))
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Clicks select on mouse-down themselves; the action carries keyboard and accessibility picks.
        control.target = context.coordinator
        control.action = #selector(Coordinator.picked(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        control.menu = menu
        return control
    }

    func updateNSView(_ control: TabSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.control = control
        control.onPick = { [weak coordinator] index in coordinator?.pick(index) }
        control.onMove = { [weak coordinator] from, to in coordinator?.move(from: from, to: to) }

        let size = NSControl.ControlSize(context.environment.controlSize)
        if control.controlSize != size {
            control.controlSize = size
            control.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        let tabs = model.analysisTabs.visible
        if coordinator.tabs != tabs {
            coordinator.tabs = tabs
            control.segmentCount = tabs.count
            for (index, tab) in tabs.enumerated() {
                control.setLabel(tab.localizedTitle, forSegment: index)
            }
        }
        control.selectedSegment = tabs.firstIndex(of: model.analysisTab) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabSegmentedControl, context: Context) -> CGSize? {
        let fitting = nsView.intrinsicContentSize
        return CGSize(width: max(proposal.width ?? fitting.width, fitting.width), height: fitting.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var model: NeodiskViewModel?
        weak var control: TabSegmentedControl?
        var tabs: [AnalysisTab] = []

        @objc func picked(_ sender: NSSegmentedControl) {
            pick(sender.selectedSegment)
        }

        func pick(_ index: Int) {
            guard tabs.indices.contains(index) else { return }
            model?.analysisTab = tabs[index]
        }

        func move(from: Int, to: Int) {
            guard tabs.indices.contains(from) else { return }
            model?.moveAnalysisTab(tabs[from], to: to)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let model else { return }
            if let index = control?.menuSegment, tabs.indices.contains(index) {
                let left = ClosureMenuItem(title: NSLocalizedString("Move Left", comment: "Statistics tab menu")) {
                    [weak self] in self?.move(from: index, to: index - 1)
                }
                left.isEnabled = index > 0
                menu.addItem(left)
                let right = ClosureMenuItem(title: NSLocalizedString("Move Right", comment: "Statistics tab menu")) {
                    [weak self] in self?.move(from: index, to: index + 1)
                }
                right.isEnabled = index < tabs.count - 1
                menu.addItem(right)
                menu.addItem(.separator())
            }
            menu.addAnalysisTabItems(model: model)
        }
    }
}

/// Selects on mouse-down; a drag then carries the segment's tab along, taking each neighbor's place as the pointer
/// passes the middle of it. AppKit doesn't expose segment frames, so they're laid out as the distribution does.
final class TabSegmentedControl: NSSegmentedControl {
    var onPick: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// The segment the open context menu was raised on.
    private(set) var menuSegment: Int?

    private var dragged: Int?
    private var dragStart: CGFloat = 0
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let index = segment(at: convert(event.locationInWindow, from: nil).x) else {
            return super.mouseDown(with: event)
        }
        dragged = index
        dragStart = convert(event.locationInWindow, from: nil).x
        isDragging = false
        if selectedSegment != index {
            selectedSegment = index
            onPick?(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragged else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        if !isDragging {
            guard abs(x - dragStart) >= 3 else { return }
            isDragging = true
        }
        // One neighbor at a time, so a fast drag still passes through every slot in order.
        let frames = segmentFrames()
        let to = if from + 1 < frames.count, x > frames[from + 1].mid {
            from + 1
        } else if from > 0, x < frames[from - 1].mid {
            from - 1
        } else {
            from
        }
        guard to != from else { return }
        dragged = to
        onMove?(from, to)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragged != nil else { return super.mouseUp(with: event) }
        dragged = nil
        isDragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuSegment = segment(at: convert(event.locationInWindow, from: nil).x)
        return super.menu(for: event)
    }

    private func segment(at x: CGFloat) -> Int? {
        guard x >= 0, x <= bounds.width else { return nil }
        return segmentFrames().firstIndex { x < $0.upperBound } ?? (segmentCount > 0 ? segmentCount - 1 : nil)
    }

    /// Each segment's span as `.fillProportionally` lays them out: shares in proportion to each title.
    private func segmentFrames() -> [ClosedRange<CGFloat>] {
        guard segmentCount > 0, bounds.width > 0 else { return [] }
        let font = font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let weights: [CGFloat] = (0..<segmentCount).map { index in
            guard let label = label(forSegment: index) else { return 1 }
            return (label as NSString).size(withAttributes: [.font: font]).width + 16
        }
        let total = weights.reduce(0, +)
        var start: CGFloat = 0
        return weights.map { weight in
            let end = start + weight / total * bounds.width
            defer { start = end }
            return start...end
        }
    }
}

private extension NSControl.ControlSize {
    init(_ size: ControlSize) {
        switch size {
        case .mini: self = .mini
        case .small: self = .small
        case .large, .extraLarge: self = .large
        default: self = .regular
        }
    }
}

private extension ClosedRange<CGFloat> {
    var mid: CGFloat { (lowerBound + upperBound) / 2 }
}
