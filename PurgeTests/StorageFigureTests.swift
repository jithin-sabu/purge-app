import Foundation
import Testing
@testable import Purge

/// The storage figures in the sidebar and the Overview are written by
/// `formatOneDecimal`, which takes its unit from the string tables and its digits and
/// decimal separator from the region. These check both ways of writing a fraction, so
/// the change that localized the unit can't quietly break the English one (#341), and
/// regions with their own digits, so the figures match the rest of the screen (#460).
@Suite("Storage figures")
struct StorageFigureTests {
    private static let us = Locale(identifier: "en_US")
    private static let russia = Locale(identifier: "ru_RU")
    private static let arabicDigits = Locale(identifier: "ar_SA@numbers=arab")
    private static let arabicWithWesternDigits = Locale(identifier: "ar_SA@numbers=latn")
    private static let persian = Locale(identifier: "fa_IR")

    @Test func fractionUsesTheRegionSeparator() {
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, locale: Self.russia) == "217,5 GB")
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, locale: Self.us) == "217.5 GB")
    }

    @Test func wholeUnitsCarryNoSeparator() {
        #expect(formatOneDecimal(28_000_000_000, roundingDown: false, locale: Self.russia) == "28 GB")
        #expect(formatOneDecimal(1_000_000_000, roundingDown: false, locale: Self.russia) == "1 GB")
    }

    @Test func ceilingsStillRoundDown() {
        #expect(formatOneDecimal(1_290_000_000, roundingDown: true, locale: Self.russia) == "1,2 GB")
        #expect(formatOneDecimal(1_999_999_999, roundingDown: true, locale: Self.us) == "1.9 GB")
        #expect(formatOneDecimal(999_999_999_999, roundingDown: true, locale: Self.us) == "999.9 GB")
    }

    @Test func nearestRoundingCarriesIntoTheWhole() {
        #expect(formatOneDecimal(1_960_000_000, roundingDown: false, locale: Self.us) == "2 GB")
        #expect(formatOneDecimal(1_940_000_000, roundingDown: false, locale: Self.us) == "1.9 GB")
    }

    @Test func unitsCoverEveryStep() {
        #expect(formatOneDecimal(2_500_000, roundingDown: false, locale: Self.us) == "2.5 MB")
        #expect(formatOneDecimal(2_500, roundingDown: false, locale: Self.us) == "2.5 KB")
        #expect(formatOneDecimal(2_500_000_000_000, roundingDown: false, locale: Self.us) == "2.5 TB")
    }

    @Test func largeFiguresHaveNoGroupingSeparator() {
        #expect(formatOneDecimal(1_234_000_000_000_000, roundingDown: false, locale: Self.us) == "1234 TB")
    }

    @Test func arabicWritesArabicIndicDigits() {
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, locale: Self.arabicDigits) == "٢١٧٫٥ GB")
        #expect(formatOneDecimal(28_000_000_000, roundingDown: false, locale: Self.arabicDigits) == "٢٨ GB")
        #expect(formatOneDecimal(1_290_000_000, roundingDown: true, locale: Self.arabicDigits) == "١٫٢ GB")
    }

    @Test func arabicWithWesternDigitsKeepsThem() {
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, locale: Self.arabicWithWesternDigits) == "217.5 GB")
        #expect(formatOneDecimal(1_290_000_000, roundingDown: true, locale: Self.arabicWithWesternDigits) == "1.2 GB")
    }

    @Test func persianWritesPersianDigits() {
        #expect(formatOneDecimal(217_500_000_000, roundingDown: false, locale: Self.persian) == "۲۱۷٫۵ GB")
    }
}
