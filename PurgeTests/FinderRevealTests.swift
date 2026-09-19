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

    /// `hasPrefix` is a string test, not a path test: a sibling home whose name merely
    /// starts with the current user's would otherwise abbreviate to `~2/cache` — a label
    /// pointing at a folder that does not exist, on a menu item that deletes things.
    @Test func siblingHomeWithAPrefixNameIsNotAbbreviated() {
        let sibling = URL(fileURLWithPath: home.path + "2/cache")
        let title = FinderReveal.menuTitle(for: ScanRowLocation(url: sibling, sizeBytes: nil))

        #expect(title == sibling.standardizedFileURL.path)
        #expect(!title.hasPrefix("~"))
    }

    /// The guard above must not cost the ordinary case: the home directory itself still
    /// abbreviates, since there is no remainder to check for a separator.
    @Test func homeDirectoryItselfAbbreviatesToTilde() {
        #expect(FinderReveal.menuTitle(for: ScanRowLocation(url: home)) == "~")
    }

    /// The submenu labels a location by its path; a trailing slash would make two
    /// spellings of the same folder look like two different rows.
    @Test func trailingSlashIsNormalized() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app/")
        let title = FinderReveal.menuTitle(for: ScanRowLocation(url: url, sizeBytes: nil))

        #expect(title == "~/Library/Caches/com.example.app")
    }

    @Test func emptyLocationsProduceNoMenu() {
        #expect(FinderReveal.menuEntries(for: []).isEmpty)
    }

    @Test func singleLocationUsesFlatShowAndCopy() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app")
        let entries = FinderReveal.menuEntries(for: [ScanRowLocation(url: url, sizeBytes: 1_000)])

        #expect(entries.count == 2)
        guard case .action(let showTitle, _) = entries[0] else {
            Issue.record("expected a flat Show in Finder action")
            return
        }
        guard case .action(let copyTitle, _) = entries[1] else {
            Issue.record("expected Copy Path")
            return
        }
        #expect(showTitle == "Show in Finder")
        #expect(copyTitle == "Copy Path")
    }

    /// Several folders become a submenu so Finder does not open one window per parent.
    /// Largest first matches the visual order on scan rows.
    @Test func multipleLocationsUseASubmenuLargestFirst() {
        let smaller = ScanRowLocation(
            url: home.appendingPathComponent("Library/Caches/small"),
            sizeBytes: 100
        )
        let larger = ScanRowLocation(
            url: home.appendingPathComponent("Library/Caches/large"),
            sizeBytes: 200
        )
        let entries = FinderReveal.menuEntries(for: [smaller, larger])

        #expect(entries.count == 2)
        guard case .submenu(let title, let sub) = entries[0] else {
            Issue.record("expected a Show in Finder submenu")
            return
        }
        guard case .action(let copyTitle, _) = entries[1] else {
            Issue.record("expected Copy Paths")
            return
        }
        #expect(title == "Show in Finder")
        #expect(copyTitle == "Copy Paths")
        #expect(sub.count == 2)
        guard case .action(let firstTitle, _) = sub[0],
              case .action(let secondTitle, _) = sub[1]
        else {
            Issue.record("expected two submenu actions")
            return
        }
        #expect(firstTitle == FinderReveal.menuTitle(for: larger))
        #expect(secondTitle == FinderReveal.menuTitle(for: smaller))
    }
}
