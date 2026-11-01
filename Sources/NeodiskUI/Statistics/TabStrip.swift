// The statistics tab bar's geometry, apart from SwiftUI so its fitting and drag math are testable: tabs laid out
// left to right after `padding`, `spacing` apart, each as wide as its label.

import CoreGraphics

struct TabStrip<Tab: Hashable> {
    let padding: CGFloat
    let spacing: CGFloat
    let widths: [Tab: CGFloat]

    private func width(_ tab: Tab) -> CGFloat { widths[tab] ?? 0 }

    private func span(_ tabs: some Collection<Tab>) -> CGFloat {
        tabs.reduce(0) { $0 + width($1) } + spacing * CGFloat(max(tabs.count - 1, 0))
    }

    /// The tabs that fit a bar `barWidth` wide, and the rest for the » menu (`menuWidth`, one `spacing` away).
    /// The active tab is always shown, in the last spot if it wouldn't fit in its own.
    func fit(_ tabs: [Tab], barWidth: CGFloat, menuWidth: CGFloat, active: Tab) -> (shown: [Tab], overflow: [Tab]) {
        let available = barWidth - 2 * padding
        guard barWidth > 0, span(tabs) > available else { return (tabs, []) }
        let room = available - menuWidth - spacing
        var count = tabs.count - 1
        while count > 1, span(tabs.prefix(count)) > room { count -= 1 }
        var shown = Array(tabs.prefix(count))
        if let index = tabs.firstIndex(of: active), index >= count {
            // It takes the last spot, and the ones before it if it's wider.
            shown[shown.count - 1] = active
            while shown.count > 1, span(shown) > room { shown.remove(at: shown.count - 2) }
        }
        return (shown, tabs.filter { !shown.contains($0) })
    }

    /// Each tab's leading edge, as the bar lays them out.
    func slots(_ shown: [Tab]) -> [Tab: CGFloat] {
        var x = padding
        var result: [Tab: CGFloat] = [:]
        for tab in shown {
            result[tab] = x
            x += width(tab) + spacing
        }
        return result
    }

    /// Where a dragged tab's leading edge may go: from the first slot to where the last tab ends.
    func clampedLeft(_ left: CGFloat, of tab: Tab, in shown: [Tab]) -> CGFloat {
        min(max(left, padding), max(padding + span(shown) - width(tab), padding))
    }

    /// The order once the dragged tab's leading edge is at `left`: it passes every neighbor whose middle its own
    /// middle has crossed, however far the pointer jumped since the last update.
    func reordered(_ shown: [Tab], dragging tab: Tab, left: CGFloat) -> [Tab] {
        guard var index = shown.firstIndex(of: tab) else { return shown }
        var order = shown
        let middle = left + width(tab) / 2
        while true {
            let slots = slots(order)
            if index + 1 < order.count, let next = slots[order[index + 1]],
               middle >= next + width(order[index + 1]) / 2 {
                order.swapAt(index, index + 1)
                index += 1
            } else if index > 0, let previous = slots[order[index - 1]],
                      middle <= previous + width(order[index - 1]) / 2 {
                order.swapAt(index, index - 1)
                index -= 1
            } else {
                return order
            }
        }
    }
}
