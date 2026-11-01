// The order and visibility of a strip the user rearranges: the statistics tabs, the file list's columns. Stored
// as one string of ids in order, hidden ones prefixed with "-".

package struct ItemLayout<Item: RawRepresentable & CaseIterable & Hashable>: Equatable where Item.RawValue == String {
    package private(set) var order: [Item]
    package private(set) var hidden: Set<Item>
    /// Always first and always shown (the file list's Name column).
    package let pinned: Item?

    package init(stored: String = "", pinned: Item? = nil) {
        self.pinned = pinned
        var order: [Item] = []
        var hidden: Set<Item> = []
        for token in stored.split(separator: ",") {
            let isHidden = token.hasPrefix("-")
            guard let item = Item(rawValue: String(isHidden ? token.dropFirst() : token[...])),
                  !order.contains(item) else { continue }
            order.append(item)
            if isHidden { hidden.insert(item) }
        }
        // Items added in a later version show up where they sit by default.
        let standard = Array(Item.allCases)
        for (index, item) in standard.enumerated() where !order.contains(item) {
            let predecessor = standard.prefix(index).last { order.contains($0) }
            order.insert(item, at: predecessor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        if let pinned {
            order.removeAll { $0 == pinned }
            order.insert(pinned, at: 0)
            hidden.remove(pinned)
        }
        if hidden.count >= order.count, let first = order.first { hidden.remove(first) }
        self.order = order
        self.hidden = hidden
    }

    package var stored: String {
        order.map { hidden.contains($0) ? "-" + $0.rawValue : $0.rawValue }.joined(separator: ",")
    }

    package var visible: [Item] { order.filter { !hidden.contains($0) } }

    package var isStandard: Bool { self == ItemLayout(pinned: pinned) }

    package func isHidden(_ item: Item) -> Bool { hidden.contains(item) }

    /// The pinned item and the last one shown stay.
    package func canHide(_ item: Item) -> Bool {
        item != pinned && !hidden.contains(item) && visible.count > 1
    }

    package mutating func setHidden(_ item: Item, _ isHidden: Bool) {
        if isHidden {
            guard canHide(item) else { return }
            hidden.insert(item)
        } else {
            hidden.remove(item)
        }
    }

    /// Puts `item` where `target` is, the way a dragged tab takes a neighbor's place: after it when coming
    /// from the left, before it when coming from the right.
    package mutating func move(_ item: Item, onto target: Item) {
        guard item != target, item != pinned, target != pinned,
              let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(item, at: to)
    }

    /// Takes the order of the shown items as given, keeping hidden ones in their slots.
    package mutating func setVisibleOrder(_ newVisible: [Item]) {
        guard Set(newVisible) == Set(visible), newVisible.first == visible.first || pinned == nil else { return }
        var queue = newVisible[...]
        order = order.map { hidden.contains($0) ? $0 : queue.popFirst() ?? $0 }
    }
}
