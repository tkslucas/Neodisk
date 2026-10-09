import Testing
@testable import NeodiskKit

/// The natural order Linux breaks size ties with (Darwin uses
/// localizedStandardCompare, which these cases agree with).
@Suite struct DisplayNameOrderTests {
    private func sorted(_ names: [String]) -> [String] {
        names.sorted { DisplayNameOrder.naturalOrder($0, $1) < 0 }
    }

    @Test func digitRunsCompareByValue() {
        #expect(sorted(["file10", "file2", "file1"]) == ["file1", "file2", "file10"])
        #expect(sorted(["v1.10.0", "v1.9.2", "v1.2"]) == ["v1.2", "v1.9.2", "v1.10.0"])
    }

    @Test func caseIsIgnoredExceptToBreakTies() {
        #expect(sorted(["banana", "Apple", "cherry"]) == ["Apple", "banana", "cherry"])
        #expect(DisplayNameOrder.naturalOrder("readme", "README") != 0)
    }

    @Test func distinctNamesNeverCompareEqual() {
        #expect(DisplayNameOrder.naturalOrder("a01", "a1") != 0)
        #expect(DisplayNameOrder.naturalOrder("a", "a") == 0)
        #expect(DisplayNameOrder.naturalOrder("a", "ab") < 0)
        #expect(DisplayNameOrder.naturalOrder("ab", "a") > 0)
    }

    @Test func orderIsAntisymmetric() {
        let names = ["x2", "X10", "x02", "a", "B", "b", "10", "9", "é", "e", "_hidden"]
        for lhs in names {
            for rhs in names where lhs != rhs {
                #expect(DisplayNameOrder.naturalOrder(lhs, rhs).signum() == -DisplayNameOrder.naturalOrder(rhs, lhs).signum())
            }
        }
    }
}
