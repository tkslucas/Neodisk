import Testing
@testable import NeodiskAppModel

private enum Column: String, CaseIterable { case name, size, files, modified }

struct ItemLayoutTests {
    @Test func emptyStoreIsTheStandardOrder() {
        let layout = ItemLayout<Column>()
        #expect(layout.order == Column.allCases)
        #expect(layout.visible == Column.allCases)
        #expect(layout.isStandard)
        #expect(layout.stored == "name,size,files,modified")
    }

    @Test func roundTripsOrderAndHidden() {
        let layout = ItemLayout<Column>(stored: "modified,-files,name,size")
        #expect(layout.order == [.modified, .files, .name, .size])
        #expect(layout.visible == [.modified, .name, .size])
        #expect(ItemLayout<Column>(stored: layout.stored) == layout)
    }

    @Test func dropsUnknownAndDuplicateIDsAndRestoresMissingOnesInPlace() {
        let layout = ItemLayout<Column>(stored: "size,bogus,size,modified")
        #expect(layout.order == [.name, .size, .files, .modified])
    }

    @Test func pinnedStaysFirstAndShown() {
        var layout = ItemLayout<Column>(stored: "size,-name,files,modified", pinned: .name)
        #expect(layout.order.first == .name)
        #expect(!layout.isHidden(.name))
        #expect(!layout.canHide(.name))
        layout.move(.size, onto: .name)
        #expect(layout.order.first == .name)
        layout.setVisibleOrder([.size, .name, .files, .modified])
        #expect(layout.order.first == .name)
    }

    @Test func neverHidesTheLastShownItem() {
        var layout = ItemLayout<Column>(stored: "-name,-size,-files,-modified")
        #expect(layout.visible == [.name])
        #expect(!layout.canHide(.name))
        layout.setHidden(.name, true)
        #expect(layout.visible == [.name])
        layout.setHidden(.files, false)
        #expect(layout.visible == [.name, .files])
    }

    @Test func moveTakesTheTargetsPlaceFromEitherSide() {
        var layout = ItemLayout<Column>()
        layout.move(.name, onto: .files)
        #expect(layout.order == [.size, .files, .name, .modified])
        layout.move(.modified, onto: .size)
        #expect(layout.order == [.modified, .size, .files, .name])
    }

    @Test func setVisibleOrderKeepsHiddenSlots() {
        var layout = ItemLayout<Column>(stored: "name,-size,files,modified")
        layout.setVisibleOrder([.name, .modified, .files])
        #expect(layout.order == [.name, .size, .modified, .files])
        #expect(layout.isHidden(.size))
    }
}
