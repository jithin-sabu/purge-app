import Foundation
import Testing
@testable import Purge

/// Covers the keeper the "keep one, delete the rest" flow suggests. It only
/// suggests — the user can override — so the bar is "reasonable and stable", not
/// "provably right". These pin the ordering so the suggestion doesn't drift.
@Suite("Duplicate keeper suggestion")
struct DuplicateKeeperTests {
    private func file(_ path: String, lastUsed: Date = Date()) -> LargeFile {
        LargeFile(
            path: URL(fileURLWithPath: path),
            sizeBytes: 9_400_000,
            lastUsed: lastUsed,
            category: .other
        )
    }

    private func suggested(_ paths: [String]) -> String? {
        DuplicateKeeper.suggestedKeeperID(among: paths.map { file($0) })
    }

    @Test
    func keepsTheRealHomeOverADownload() {
        let keeper = suggested([
            "/Users/x/Downloads/snapshot.sqlite",
            "/Users/x/Documents/grocery/App/Resources/snapshot.sqlite",
        ])
        #expect(keeper == "/Users/x/Documents/grocery/App/Resources/snapshot.sqlite")
    }

    @Test
    func keepsTheRealHomeOverABuildArtifact() {
        let keeper = suggested([
            "/Users/x/Documents/grocery/App/Resources/snapshot.sqlite",
            "/Users/x/Documents/grocery/DerivedData/Build/snapshot.sqlite",
            "/Users/x/Documents/grocery/App/node_modules/pkg/snapshot.sqlite",
        ])
        #expect(keeper == "/Users/x/Documents/grocery/App/Resources/snapshot.sqlite")
    }

    @Test
    func prefersADownloadOverACache() {
        let keeper = suggested([
            "/Users/x/Library/Caches/app/snapshot.sqlite",
            "/Users/x/Downloads/snapshot.sqlite",
        ])
        #expect(keeper == "/Users/x/Downloads/snapshot.sqlite")
    }

    @Test
    func keepsTheCanonicalNameOverACopy() {
        let keeper = suggested([
            "/Users/x/Documents/snapshot copy.sqlite",
            "/Users/x/Documents/snapshot.sqlite",
            "/Users/x/Documents/snapshot copy 2.sqlite",
        ])
        #expect(keeper == "/Users/x/Documents/snapshot.sqlite")
    }

    @Test
    func treatsParenthesizedNumberAsACopy() {
        let keeper = suggested([
            "/Users/x/Documents/report (1).pdf",
            "/Users/x/Documents/report.pdf",
        ])
        #expect(keeper == "/Users/x/Documents/report.pdf")
    }

    /// Nothing separates two same-location, same-kind names but the path, so the
    /// pick has to be stable rather than order-dependent.
    @Test
    func breaksTiesDeterministically() {
        let paths = [
            "/Users/x/Documents/b/snapshot.sqlite",
            "/Users/x/Documents/a/snapshot.sqlite",
        ]
        #expect(suggested(paths) == "/Users/x/Documents/a/snapshot.sqlite")
        #expect(suggested(paths.reversed()) == "/Users/x/Documents/a/snapshot.sqlite")
    }

    @Test
    func emptyGroupHasNoKeeper() {
        #expect(DuplicateKeeper.suggestedKeeperID(among: []) == nil)
    }
}
