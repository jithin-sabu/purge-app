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
    func keepsTheRealHomeOverATemporaryOrCachedCopy() {
        let keeper = suggested([
            "/Users/x/Documents/models/whisper/large.pt",
            "/Users/x/Documents/a/tmp/large.pt",
            "/Users/x/.cache/whisper/large.pt",
        ])
        #expect(keeper == "/Users/x/Documents/models/whisper/large.pt")
    }

    /// A marker for a folder no duplicate can come from would never fire, and
    /// would read as a signal the keeper uses when it isn't (#190). Each one
    /// must sit where the Large Files walk goes or under an AI model root.
    @Test(arguments: DuplicateKeeper.disposableFolders)
    func everyDisposableFolderCanHoldARow(marker: String) {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        let walked = home.appendingPathComponent("Documents" + marker + "file.bin")
        let modelRoots = AIModelScanPolicy.looseWeightRoots(home: home)
            + AIModelScanPolicy.allRoots(home: home, environment: [:])
        let underModelRoot = modelRoots.contains { ($0.path + "/").lowercased().contains(marker) }
        #expect(!LargeFileScanPolicy.isInsideExcludedDirectory(walked) || underModelRoot)
    }

    /// Finder names a duplicate in the Mac's language, so `Bericht Kopie.pdf` on
    /// a German Mac is as much a copy as `report copy.pdf`.
    @Test(arguments: DuplicateKeeper.finderCopyNames)
    func keepsTheOriginalOverAFinderCopy(template: String) {
        let copy = template.replacingOccurrences(of: "{name}", with: "report")
            .replacingOccurrences(of: "{n}", with: "2")
        let keeper = suggested([
            "/Users/x/Documents/\(copy).pdf",
            "/Users/x/Documents/report.pdf",
        ])
        #expect(keeper == "/Users/x/Documents/report.pdf", "\(copy) was not read as a copy")
    }

    /// Names on disk can be decomposed, with an accent stored as its own character.
    @Test
    func readsADecomposedCopyName() {
        let copy = "report - cópia".decomposedStringWithCanonicalMapping
        let keeper = suggested([
            "/Users/x/Documents/\(copy).pdf",
            "/Users/x/Documents/report.pdf",
        ])
        #expect(keeper == "/Users/x/Documents/report.pdf")
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
