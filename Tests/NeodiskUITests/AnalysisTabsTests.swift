import AppKit
import Testing
@testable import NeodiskUI

/// Moving and hiding the statistics tabs, as the tab bar's drag and menus do.
@MainActor
struct AnalysisTabsTests {
    private func model() -> NeodiskViewModel {
        NeodiskViewModel(snapshotCache: makeIsolatedCache())
    }

    @Test func aMovedTabTakesItsNewPlace() {
        let model = model()
        model.moveAnalysisTab(.largest, to: 2)
        #expect(model.analysisTabs.visible == [.kinds, .age, .largest, .duplicates, .changes])
        model.moveAnalysisTab(.largest, to: 1)
        #expect(model.analysisTabs.visible == [.kinds, .largest, .age, .duplicates, .changes])
    }

    @Test func movesStayAmongTheShownTabs() {
        let model = model()
        model.setAnalysisTab(.age, shown: false)
        model.moveAnalysisTab(.changes, to: 0)
        #expect(model.analysisTabs.visible == [.changes, .largest, .kinds, .duplicates])
        // Out of range: nothing moves.
        model.moveAnalysisTab(.changes, to: 9)
        #expect(model.analysisTabs.visible == [.changes, .largest, .kinds, .duplicates])
        model.setAnalysisTab(.age, shown: true)
        #expect(model.analysisTabs.visible.contains(.age))
    }

    @Test func arrowKeysSwitchToTheNeighboringTab() throws {
        let control = TabSegmentedControl()
        control.segmentCount = 3
        control.trackingMode = .selectOne
        control.selectedSegment = 0
        var picked: [Int] = []
        control.onPick = { picked.append($0) }
        func key(_ code: UInt16, _ scalar: Int) throws -> NSEvent {
            let chars = String(try #require(UnicodeScalar(scalar)))
            return try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
            ))
        }
        control.keyDown(with: try key(124, NSRightArrowFunctionKey))
        control.keyDown(with: try key(124, NSRightArrowFunctionKey))
        control.keyDown(with: try key(124, NSRightArrowFunctionKey))
        control.keyDown(with: try key(123, NSLeftArrowFunctionKey))
        #expect(picked == [1, 2, 1])
        #expect(control.selectedSegment == 1)
    }
}
