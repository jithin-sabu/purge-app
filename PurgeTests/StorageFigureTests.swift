import Foundation
import Testing
@testable import Purge

/// The storage figures in the sidebar and the Overview are written by
/// `formatOneDecimal`, which takes its unit from the string tables and its decimal
/// separator from the region. These check both ways of writing a fraction, so the
/// change that localized the unit can't quietly break the English one (#341).
@Suite("Storage figures")
struct StorageFigureTests {
    @Test func fractionUsesTheRegionSeparator() {
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, decimalSeparator: ",") == "217,5 GB")
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, decimalSeparator: ".") == "217.5 GB")
    }

    @Test func wholeUnitsCarryNoSeparator() {
        #expect(formatOneDecimal(28_000_000_000, roundingDown: false, decimalSeparator: ",") == "28 GB")
        #expect(formatOneDecimal(1_000_000_000, roundingDown: false, decimalSeparator: ",") == "1 GB")
    }

    @Test func ceilingsStillRoundDown() {
        #expect(formatOneDecimal(1_290_000_000, roundingDown: true, decimalSeparator: ",") == "1,2 GB")
        #expect(formatOneDecimal(1_999_999_999, roundingDown: true, decimalSeparator: ".") == "1.9 GB")
    }

    @Test func unitsCoverEveryStep() {
        #expect(formatOneDecimal(2_500_000, roundingDown: false, decimalSeparator: ".") == "2.5 MB")
        #expect(formatOneDecimal(2_500, roundingDown: false, decimalSeparator: ".") == "2.5 KB")
        #expect(formatOneDecimal(2_500_000_000_000, roundingDown: false, decimalSeparator: ".") == "2.5 TB")
    }
}
