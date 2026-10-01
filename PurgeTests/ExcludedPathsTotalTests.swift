import Foundation
import Testing
@testable import Purge

@Suite("Settings total for excluded paths")
struct ExcludedPathsTotalTests {
    /// Excluding a file and then its folder leaves both rows listed. The folder's
    /// size already includes the file, so the file must not be added again.
    @Test
    func parentAddedAfterChildCountsOnce() {
        let total = ExcludedPathsTotal.compute(
            paths: ["/Users/me/Downloads/Archive/film.mov", "/Users/me/Downloads/Archive"],
            sizes: [
                "/Users/me/Downloads/Archive/film.mov": .measured(700),
                "/Users/me/Downloads/Archive": .measured(1_000),
            ]
        )
        #expect(total == ExcludedPathsTotal(bytes: 1_000, isComplete: true, hasUnmeasured: false))
    }

    @Test
    func siblingWithSharedPrefixIsNotNested() {
        #expect(
            ExcludedPathsTotal.topLevel(["/Users/me/Movie", "/Users/me/Movies"]).sorted()
                == ["/Users/me/Movie", "/Users/me/Movies"]
        )
    }

    /// A folder `du` couldn't read is not 0 bytes, so the total is a floor.
    @Test
    func unmeasurablePathMakesTheTotalAFloor() {
        let total = ExcludedPathsTotal.compute(
            paths: ["/a", "/b"],
            sizes: ["/a": .measured(5), "/b": .unmeasurable]
        )
        #expect(total == ExcludedPathsTotal(bytes: 5, isComplete: true, hasUnmeasured: true))
    }

    /// While a row is still loading, the total must not look final.
    @Test
    func loadingPathKeepsTheTotalIncomplete() {
        let total = ExcludedPathsTotal.compute(paths: ["/a", "/b"], sizes: ["/a": .measured(5)])
        #expect(!total.isComplete)
    }

    @Test
    func missingPathAddsNothingAndStillCompletes() {
        let total = ExcludedPathsTotal.compute(paths: ["/a", "/gone"], sizes: ["/a": .measured(5), "/gone": .missing])
        #expect(total == ExcludedPathsTotal(bytes: 5, isComplete: true, hasUnmeasured: false))
    }
}
