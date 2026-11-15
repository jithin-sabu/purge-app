import Foundation
import Testing
@testable import Purge

/// The App Uninstaller's header names the folders only when an app comes from
/// a drive or a folder the user added (#99). Paths only, no disk.
@Suite("Where the listed apps come from (#99)")
struct AppFolderSummaryTests {
    private let builtIn: Set<String> = ["/Applications", "/Users/me/Applications"]
    private let builtInRoots = ["/Applications", "/Users/me/Applications"]

    @Test("Apps only in the two Applications folders say nothing")
    func builtInOnlyStaysQuiet() {
        let summary = AppFolderSummary.make(
            appPaths: ["/Applications/VLC.app", "/Applications/Utilities/Tool.app", "/Users/me/Applications/Mine.app"],
            roots: builtInRoots,
            builtIn: builtIn,
            added: []
        )
        #expect(!summary.isWorthShowing)
        #expect(summary.folders.map(\.appCount) == [2, 1])
    }

    @Test("A drive's Applications folder with no apps in it says nothing")
    func emptyDriveFolderStaysQuiet() {
        let summary = AppFolderSummary.make(
            appPaths: ["/Applications/VLC.app"],
            roots: builtInRoots + ["/Volumes/SSD/Applications"],
            builtIn: builtIn,
            added: []
        )
        #expect(!summary.isWorthShowing)
        #expect(summary.folders.map(\.path) == ["/Applications"])
    }

    @Test("An app on a drive turns the line on, and only folders with apps count")
    func driveAppTurnsItOn() {
        let summary = AppFolderSummary.make(
            appPaths: ["/Applications/VLC.app", "/Volumes/SSD/Applications/Luminar Neo.app", "/Volumes/SSD/Applications/UTM.app"],
            roots: builtInRoots + ["/Volumes/SSD/Applications"],
            builtIn: builtIn,
            added: [],
            driveNames: ["/Volumes/SSD/Applications": "SSD"]
        )
        #expect(summary.isWorthShowing)
        #expect(summary.folders.map(\.name) == ["/Applications", "SSD"])
        #expect(summary.folders.map(\.appCount) == [1, 2])
    }

    @Test("A folder the user added always counts, even when its drive is out")
    func addedFolderAlwaysCounts() {
        let summary = AppFolderSummary.make(
            appPaths: ["/Applications/VLC.app"],
            roots: builtInRoots,
            builtIn: builtIn,
            added: ["/Volumes/Archive/Old Apps"]
        )
        #expect(summary.isWorthShowing)
        #expect(summary.folders.last?.name == "Old Apps")
        #expect(summary.folders.last?.appCount == 0)
        #expect(summary.folders.last?.kind == .added)
        #expect(summary.folders.last?.isAvailable == false)
    }

    @Test("An added folder that is there now is available, even with no apps")
    func presentAddedFolderIsAvailable() {
        let summary = AppFolderSummary.make(
            appPaths: ["/Applications/VLC.app"],
            roots: builtInRoots + ["/Volumes/SSD/Tools"],
            builtIn: builtIn,
            added: ["/Volumes/SSD/Tools"]
        )
        #expect(summary.folders.last?.isAvailable == true)
        #expect(summary.folders.last?.appCount == 0)
        #expect(summary.folders.allSatisfy { $0.isAvailable })
    }
}
