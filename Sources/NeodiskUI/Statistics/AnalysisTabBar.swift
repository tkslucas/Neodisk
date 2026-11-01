// The statistics tabs: text tabs, each title whole. Tabs that don't fit the pane's width go in a » menu instead of
// truncating; the active one always shows. Dragging a tab moves the tab itself (no drag image): its neighbors slide
// aside as it crosses their middles, and it settles into its slot on release. Right-clicking a tab moves it left or
// right and shows or hides tabs; ← and → switch tabs once the bar has keyboard focus.

import AppKit
import SwiftUI
import NeodiskAppModel

extension AnalysisTab {
    var localizedTitle: String { NSLocalizedString(title, comment: "Statistics tab") }
}

struct AnalysisTabBar: View {
    let model: NeodiskViewModel

    @Namespace private var underlineNamespace
    @Environment(\.neoTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var width: CGFloat = 0
    @State private var drag: TabDrag?

    private struct TabDrag: Equatable {
        let tab: AnalysisTab
        /// Where in the tab the pointer took hold of it.
        let grab: CGFloat
        /// The tab's leading edge, following the pointer.
        var left: CGFloat
    }

    private static let space = "analysisTabBar"

    var body: some View {
        let strip = strip
        let (shown, overflow) = fitting(strip)
        HStack(spacing: strip.spacing) {
            ForEach(shown) { tab in
                AnalysisTabButton(
                    tab: tab,
                    isActive: model.analysisTab == tab,
                    showsFocus: isFocused && model.analysisTab == tab,
                    namespace: underlineNamespace
                ) {
                    select(tab)
                }
                .offset(x: offset(of: tab, in: shown, strip: strip))
                .zIndex(drag?.tab == tab ? 1 : 0)
                .transaction { if drag?.tab == tab { $0.animation = nil } }
                .simultaneousGesture(reorderGesture(for: tab))
                .contextMenu { tabMenu(for: tab) }
                .accessibilityAction(named: Text("Move Left")) { move(tab, by: -1) }
                .accessibilityAction(named: Text("Move Right")) { move(tab, by: 1) }
            }
            Spacer(minLength: 0)
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { tab in
                        Button(LocalizedStringKey(tab.title)) { select(tab) }
                    }
                } label: {
                    Image(systemName: "chevron.right.2")
                        .neoFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(height: 20 * textScale)
                        .contentShape(Rectangle())
                }
                // A plain button, so the chevron draws in the inactive tabs' gray and scales with them.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .neoHelp("More tabs")
            }
        }
        .padding(.horizontal, strip.padding)
        // minWidth 0: the bar measures the pane, not its own tabs.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .coordinateSpace(name: Self.space)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .contextMenu { AnalysisTabsMenuItems(model: model) }
        // One stop in the key loop, as AppKit's tab controls are: only with keyboard navigation on, and a click
        // never takes focus from the list.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        // The arrows already pick the tab they land on; Space keeps it, without the beep of an unhandled key.
        .onKeyPress(.space) { .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Statistics"))
    }

    private var settle: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }

    private func select(_ tab: AnalysisTab) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            model.analysisTab = tab
        }
    }

    /// Steps through every shown tab, the » menu's too: one picked from there takes the bar's last spot.
    private func step(_ step: Int) -> KeyPress.Result {
        let tabs = model.analysisTabs.visible
        guard let index = tabs.firstIndex(of: model.analysisTab) else { return .ignored }
        let target = index + step
        if tabs.indices.contains(target) { select(tabs[target]) }
        return .handled
    }

    private func move(_ tab: AnalysisTab, by step: Int) {
        guard let index = model.analysisTabs.visible.firstIndex(of: tab) else { return }
        withAnimation(settle) { model.moveAnalysisTab(tab, to: index + step) }
    }

    @ViewBuilder
    private func tabMenu(for tab: AnalysisTab) -> some View {
        let tabs = model.analysisTabs.visible
        let index = tabs.firstIndex(of: tab) ?? 0
        Button("Move Left") { move(tab, by: -1) }
            .disabled(index == 0)
        Button("Move Right") { move(tab, by: 1) }
            .disabled(index >= tabs.count - 1)
        Divider()
        AnalysisTabsMenuItems(model: model)
    }

    // MARK: Dragging

    private func offset(of tab: AnalysisTab, in shown: [AnalysisTab], strip: TabStrip<AnalysisTab>) -> CGFloat {
        guard let drag, drag.tab == tab, let slot = strip.slots(shown)[tab] else { return 0 }
        return drag.left - slot
    }

    /// Reads the bar afresh on every update rather than capturing it: each swap changes the slots.
    private func reorderGesture(for tab: AnalysisTab) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let strip = strip
                let (shown, overflow) = fitting(strip)
                guard let slot = strip.slots(shown)[tab] else { return }
                // A drag of another tab that never ended (its tab left the bar mid-drag) doesn't carry over.
                var current = TabDrag(tab: tab, grab: value.startLocation.x - slot, left: slot)
                if let drag, drag.tab == tab {
                    current = drag
                } else if model.analysisTab != tab {
                    select(tab)
                }
                let held = value.location.x - current.grab
                current.left = strip.clampedLeft(held, of: tab, in: shown)
                drag = current
                // The order follows the pointer, not the clamped tab: a wide tab pushed past the bar's edge still
                // passes a narrower first or last one, whose middle its clamped middle would never reach.
                let order = strip.reordered(shown, dragging: tab, left: held)
                guard order != shown else { return }
                // The » menu's tabs follow the shown ones, so a tab shown out of order stays where it was dropped.
                var layout = model.analysisTabs
                layout.setVisibleOrder(order + overflow)
                withAnimation(settle) { model.setAnalysisTabs(layout) }
            }
            .onEnded { _ in
                withAnimation(settle) { drag = nil }
            }
    }

    // MARK: Fitting

    /// Measured in the font the tabs draw with, so the slots match the laid-out tabs. The leading edge lines up
    /// with the lists' content; spacing grows with the text, so a bigger title isn't crowded by its neighbors.
    private var strip: TabStrip<AnalysisTab> {
        let font = NSFont.systemFont(ofSize: 11 * textScale, weight: .medium)
        let widths = Dictionary(uniqueKeysWithValues: AnalysisTab.allCases.map { tab in
            (tab, (tab.localizedTitle as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
        })
        return TabStrip(padding: StatsListMetrics.inset, spacing: (12 * textScale).rounded(), widths: widths)
    }

    /// The shown tabs that fit the bar's width, always including the active one, and the rest.
    private func fitting(_ strip: TabStrip<AnalysisTab>) -> (shown: [AnalysisTab], overflow: [AnalysisTab]) {
        strip.fit(
            model.analysisTabs.visible, barWidth: width,
            menuWidth: (16 * textScale).rounded(), active: model.analysisTab
        )
    }
}

/// Fixed weight so the active state never shifts layout.
private struct AnalysisTabButton: View {
    @Environment(\.neoTextScale) private var textScale

    let tab: AnalysisTab
    let isActive: Bool
    let showsFocus: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(tab.title))
                .neoFont(11, weight: .medium)
                .foregroundStyle(
                    isActive ? Color.accentColor : isHovering ? Color.primary : Color.secondary
                )
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, (7 * textScale).rounded())
                .overlay(alignment: .bottom) {
                    if isActive {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(height: (2 * textScale).rounded())
                            .matchedGeometryEffect(id: "analysisTabUnderline", in: namespace)
                    }
                }
                .background {
                    if showsFocus {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                            .padding(.horizontal, -4)
                            .padding(.vertical, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The bar is the one key-loop stop; the arrows move between its tabs.
        .focusable(false)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Which tabs show, for the pane's SwiftUI menus (its tabs, headers and empty space) and View > Statistics Tabs.
struct AnalysisTabsMenuItems: View {
    let model: NeodiskViewModel

    var body: some View {
        let layout = model.analysisTabs
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
    /// AppKit's copy of AnalysisTabsMenuItems, for menus AppKit builds: the lists' empty space.
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
