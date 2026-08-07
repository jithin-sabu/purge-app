import Foundation
import Testing
@testable import Purge

/// A multi-location row reveals folders through a "Show in Finder" submenu, and each
/// entry's label is the only place the user sees *which* folder holds the bulk. These
/// pin that label: abbreviated path, plus a size only when one is actually known.
@Suite("Finder reveal menu labels")
@MainActor
struct FinderRevealTests {
    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    @Test func homeRelativePathIsAbbreviated() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app")
        let title = FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: nil))

        #expect(title == "~/Library/Caches/com.example.app")
    }

    @Test func pathOutsideHomeStaysAbsolute() {
        let title = FinderReveal.menuTitle(
            for: ScanRowLocation(url: URL(fileURLWithPath: "/Library/Caches/com.example.app"))
        )

        #expect(title == "/Library/Caches/com.example.app")
    }

    @Test func knownSizeIsAppended() {
        let url = home.appendingPathComponent("go/pkg/mod")
        let title = FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: 4_200_000_000))

        #expect(title == "~/go/pkg/mod — \(formatBytes(4_200_000_000))")
    }

    /// Sizes arrive asynchronously after a scan, so a location can legitimately have no
    /// size yet. A bare "— Zero KB" would read as an empty folder rather than a pending one.
    @Test func unknownSizeIsOmittedRatherThanShownAsZero() {
        let url = home.appendingPathComponent("go/pkg/mod")

        #expect(
            FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: nil)) == "~/go/pkg/mod"
        )
        #expect(
            FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: 0)) == "~/go/pkg/mod"
        )
    }

    /// The submenu labels a location by its path; a trailing slash would make two
    /// spellings of the same folder look like two different rows.
    @Test func trailingSlashIsNormalized() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app/")
        let title = FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: nil))

        #expect(title == "~/Library/Caches/com.example.app")
    }
}
