import Foundation
import Testing
@testable import Purge

private let kb: Int64 = 1024
private let mb: Int64 = 1024 * 1024
private let gb: Int64 = 1024 * 1024 * 1024

/// Leading count in a label like "47× the English Wikipedia" or "19 CDs".
private func leadingCount(_ label: String) -> Int? {
    let digits = label.prefix { $0.isNumber || $0 == "," }
    return Int(digits.filter(\.isNumber))
}

@Suite("Size comparison catalog")
struct SizeComparisonCatalogTests {
    @Test func returnsNothingForEmptyOrNegativeSizes() {
        #expect(SizeComparisonCatalog.item(for: 0) == nil)
        #expect(SizeComparisonCatalog.item(for: -1 * gb) == nil)
    }

    @Test("Every size from 1 MB to 3 TB gets a comparison")
    func coversTheRealisticRange() {
        var bytes = mb
        while bytes < 3 * 1024 * gb {
            #expect(SizeComparisonCatalog.item(for: bytes) != nil, "no comparison for \(bytes) bytes")
            bytes = Int64(Double(bytes) * 1.05)
        }
    }

    /// A "1×" comparison is not a flex, and a seven-digit multiplier is noise.
    @Test("Multipliers stay in a quotable range")
    func keepsMultipliersQuotable() {
        var bytes = mb
        while bytes < 3 * 1024 * gb {
            let label = SizeComparisonCatalog.item(for: bytes)?.label ?? ""
            let count = leadingCount(label)
            #expect(count != nil, "no leading count in \(label)")
            #expect(count ?? 0 >= 2, "\(label) at \(bytes) bytes")
            #expect(count ?? 0 <= 20_000, "\(label) at \(bytes) bytes")
            bytes = Int64(Double(bytes) * 1.05)
        }
    }

    /// Both chips that render these are `lineLimit(1)`, so long labels truncate.
    @Test("Labels stay short enough for a single-line chip")
    func keepsLabelsShort() {
        var bytes = mb
        while bytes < 3 * 1024 * gb {
            let label = SizeComparisonCatalog.item(for: bytes)?.label ?? ""
            #expect(label.count <= 32, "too long: \(label)")
            bytes = Int64(Double(bytes) * 1.05)
        }
    }

    /// Selection mixes the byte count by hand precisely so it survives relaunch;
    /// `Hasher` is seeded per process and would drift.
    @Test func picksTheSameAnchorForTheSameSize() {
        for bytes in [7 * mb, 250 * mb, 3 * gb, 512 * gb] {
            let first = SizeComparisonCatalog.item(for: bytes)
            #expect(first == SizeComparisonCatalog.item(for: bytes))
        }
    }

    @Test(arguments: [
        (1024 * gb, "47× the English Wikipedia"),
        (13 * gb, "18× the human genome"),
        (20 * mb, "20× Pokémon Red"),
    ])
    func producesExpectedLabels(bytes: Int64, expected: String) {
        #expect(SizeComparisonCatalog.item(for: bytes)?.label == expected)
    }

    @Test("Results line stays quiet below a megabyte")
    func onboardingSuppressesTinySizes() {
        #expect(OnboardingSizeComparison.items(for: 400 * kb) == nil)
        #expect(OnboardingSizeComparison.items(for: 40 * mb)?.count == 1)
    }
}
