import Foundation
import Testing
@testable import Purge

private let kb: Int64 = 1024
private let mb: Int64 = 1024 * 1024
private let gb: Int64 = 1024 * 1024 * 1024

/// Walks sizes from 5 MB to 3 TB in 5% steps, the range a clean or a
/// lifetime total realistically covers.
private func realisticSizes() -> [Int64] {
    var sizes: [Int64] = []
    var bytes = 5 * mb
    while bytes < 3 * 1024 * gb {
        sizes.append(bytes)
        bytes = Int64(Double(bytes) * 1.05)
    }
    return sizes
}

/// Every check reads `displayLabel`, the text the chips and lines show. The test
/// host runs in English, so that is the English text.
@Suite("Size comparison catalog")
struct SizeComparisonCatalogTests {
    @Test func returnsNothingForEmptyOrNegativeSizes() {
        #expect(SizeComparisonCatalog.item(for: 0) == nil)
        #expect(SizeComparisonCatalog.item(for: -1 * gb) == nil)
    }

    @Test("Every size from 5 MB to 3 TB gets a comparison")
    func coversTheRealisticRange() {
        for bytes in realisticSizes() {
            #expect(SizeComparisonCatalog.item(for: bytes) != nil, "no comparison for \(bytes) bytes")
        }
    }

    /// Counts of one use the singular phrasing, so a digit 0 or 1 never leads.
    @Test("Labels never lead with a count of zero or one")
    func usesSingularPhrasingForOne() {
        for bytes in realisticSizes() {
            let label = SizeComparisonCatalog.item(for: bytes)?.displayLabel ?? ""
            #expect(!label.hasPrefix("0 ") && !label.hasPrefix("1 "), "\(label) at \(bytes) bytes")
        }
    }

    /// "Room for" is a promise: the freed space has to hold every copy named.
    @Test("Counts round down so the space really fits them")
    func roundsCountsDown() {
        #expect(SizeComparisonCatalog.item(for: 11 * gb)?.displayLabel != "the next macOS update")
        #expect(SizeComparisonCatalog.item(for: 99 * mb)?.displayLabel == "49 more screenshots")
    }

    /// Every chip that renders these is `lineLimit(1)`, so long labels truncate.
    @Test("Labels stay short enough for a single-line chip")
    func keepsLabelsShort() {
        for bytes in realisticSizes() {
            let label = SizeComparisonCatalog.item(for: bytes)?.displayLabel ?? ""
            #expect(label.count <= 32, "too long: \(label)")
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
        (50 * mb, "25 more screenshots"),
        (1 * gb, "Slack, twice over"),
        (15 * gb, "the next macOS update"),
        (20 * gb, "Photoshop, 4 times over"),
        (36 * gb, "3 copies of Xcode"),
        (315 * gb, "GTA V, 3 times over"),
        (1024 * gb, "4 full base MacBook Airs"),
    ])
    func producesExpectedLabels(bytes: Int64, expected: String) {
        #expect(SizeComparisonCatalog.item(for: bytes)?.displayLabel == expected)
    }

    @Test("Stays quiet below 5 MB")
    func suppressesTinySizes() {
        #expect(SizeComparisonCatalog.item(for: 4 * mb) == nil)
        #expect(OnboardingSizeComparison.items(for: 400 * kb) == nil)
        #expect(OnboardingSizeComparison.items(for: 40 * mb)?.count == 1)
    }
}
