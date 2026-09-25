import CoreServices
import Foundation
import Testing
@testable import Purge

@Suite("Removed-app watch decides when leftovers get a review")
struct RemovedAppWatchPolicyTests {
    private let safe = SafetyInfo(
        level: .safe,
        headline: "",
        explanation: "",
        recoverySteps: "",
        reinstallCommand: nil
    )

    private func makeApp(
        name: String = "Rectangle",
        bundlePath: String = "/Applications/Rectangle.app",
        bundleID: String? = "com.knollsoft.Rectangle"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    private func item(
        _ path: String,
        category: UninstallCategory,
        reason: MatchReason,
        isSelected: Bool = true
    ) -> UninstallItem {
        UninstallItem(
            path: URL(fileURLWithPath: path),
            sizeBytes: 10,
            category: category,
            safetyInfo: safe,
            matchReason: reason,
            isSelected: isSelected
        )
    }

    // MARK: Paths

    @Test
    func normalizesDataVolumeAndTrailingSlash() {
        #expect(RemovedAppWatchPolicy.normalizedPath("/System/Volumes/Data/Applications/") == "/Applications")
        #expect(RemovedAppWatchPolicy.normalizedPath("/Applications/Foo.app/") == "/Applications/Foo.app")
        #expect(RemovedAppWatchPolicy.normalizedPath("/") == "/")
    }

    @Test
    func onlyTopLevelChangesAreRelevant() {
        let roots = ["/Applications", "/Users/x/Applications"]
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Utilities/", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Users/x/Applications", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/System/Volumes/Data/Applications/", roots: roots))
        // Churn inside a bundle during an update or launch.
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Foo.app/Contents/", roots: roots))
        // A sibling folder that only shares the root's prefix.
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications Old/", roots: roots))
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Library/", roots: roots))
    }

    @Test
    func departedAppsAreThoseMissingFromTheNewIndex() {
        let kept = makeApp(name: "Kept", bundlePath: "/Applications/Kept.app", bundleID: "com.x.kept")
        let gone = makeApp(name: "Gone", bundlePath: "/Applications/Gone.app", bundleID: "com.x.gone")
        let added = makeApp(name: "New", bundlePath: "/Applications/New.app", bundleID: "com.x.new")
        let departed = RemovedAppWatchPolicy.departedApps(
            previous: [kept.id: kept, gone.id: gone],
            current: [kept.id: kept, added.id: added]
        )
        #expect(departed.map(\.id) == [gone.id])
    }

    // MARK: Review decision

    @Test
    func offersReviewForAnAppThatIsReallyGone() {
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: ["com.other.app"],
            removedByPurge: false
        ))
    }

    @Test
    func updateThatPutTheBundleBackIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: true,
            installedBundleIDs: [],
            removedByPurge: false
        ))
    }

    /// Moved into a vendor folder, renamed, or a second copy staying: its support
    /// files are still in use. Identifiers compare case-insensitively.
    @Test
    func sameIdentifierStillInstalledIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: ["com.knollsoft.rectangle"],
            removedByPurge: false
        ))
    }

    @Test
    func purgeOwnUninstallIsNotReviewedTwice() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: [],
            removedByPurge: true
        ))
    }

    @Test
    func appsWithoutAnIdentifierOrPurgeItselfAreSkipped() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(bundleID: nil),
            bundleStillExists: false,
            installedBundleIDs: [],
            removedByPurge: false
        ))
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(name: "Purge", bundlePath: "/Applications/Purge.app", bundleID: "io.getpurge.app"),
            bundleStillExists: false,
            installedBundleIDs: [],
            removedByPurge: false
        ))
    }

    // MARK: Review rows

    @Test
    func reviewDropsTheBundleAndPreselectsOnlyIdentifierMatches() {
        let owner = makeApp()
        let home = "/Users/x/Library"
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Applications/Rectangle.app", category: .bundle, reason: .appBundle),
                item("\(home)/Preferences/com.knollsoft.Rectangle.plist", category: .preferences, reason: .bundleID),
                item("\(home)/Application Support/Rectangle", category: .applicationSupport, reason: .appName)
            ],
            owner: owner,
            survivors: []
        )
        #expect(rows.map(\.category) == [.preferences, .applicationSupport])
        #expect(rows.map(\.isSelected) == [true, false])
    }

    /// A folder named after the removed app that a kept app also claims by name
    /// must not be offered at all.
    @Test
    func reviewLeavesOutLeftoversAnInstalledAppStillClaims() {
        let owner = makeApp(name: "Notes", bundlePath: "/Applications/Notes.app", bundleID: "com.a.notes")
        let survivor = makeApp(name: "Notes", bundlePath: "/Applications/Other/Notes.app", bundleID: "com.b.notes")
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Users/x/Library/Application Support/Notes", category: .applicationSupport, reason: .appName),
                item("/Users/x/Library/Preferences/com.a.notes.plist", category: .preferences, reason: .bundleID)
            ],
            owner: owner,
            survivors: [survivor]
        )
        #expect(rows.map(\.path.lastPathComponent) == ["com.a.notes.plist"])
    }
}

@Suite("Applications folder watcher", .serialized)
@MainActor
struct ApplicationsFolderWatcherTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-watch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeBundle(in folder: URL, name: String, bundleID: String) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    @Test
    func snapshotIndexesTopLevelAndVendorFolderBundles() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let vendor = root.appendingPathComponent("Vendor", isDirectory: true)
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeBundle(in: vendor, name: "Beta", bundleID: "com.test.beta")

        let snapshot = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: [:])
        #expect(Set(snapshot.values.compactMap(\.bundleID)) == ["com.test.alpha", "com.test.beta"])
        #expect(Set(snapshot.values.map(\.name)) == ["Alpha", "Beta"])
    }

    /// A root that exists but cannot be listed must not read as "every app deleted".
    @Test
    func unreadableRootKeepsItsPreviousEntries() throws {
        let root = try makeRoot()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let before = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: [:])
        #expect(before.count == 1)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let after = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: before)
        #expect(RemovedAppWatchPolicy.departedApps(previous: before, current: after).isEmpty)
    }

    /// End to end through FSEvents: a bundle moved out is reported once it has stayed
    /// gone through the settle delay, and one swapped in place (an update) is not.
    @Test(.timeLimit(.minutes(1)))
    func reportsABundleThatLeavesButNotOneThatIsReplaced() async throws {
        let root = try makeRoot()
        let elsewhere = try makeRoot()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: elsewhere)
        }
        let leaving = try makeBundle(in: root, name: "Leaving", bundleID: "com.test.leaving")
        let updating = try makeBundle(in: root, name: "Updating", bundleID: "com.test.updating")

        let watcher = ApplicationsFolderWatcher(roots: [root])
        var departures: [ApplicationsFolderWatcher.Departure] = []
        watcher.onDeparture = { departures.append($0) }
        watcher.start()
        defer { watcher.stop() }

        // Wait for the initial index before touching anything.
        for _ in 0..<50 where watcher.installedApps.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 2)
        // FSEvents needs a moment after the stream starts before it reports.
        try await Task.sleep(nanoseconds: 500_000_000)

        try fm.moveItem(at: leaving, to: elsewhere.appendingPathComponent("Leaving.app"))
        let staged = elsewhere.appendingPathComponent("Updating.app")
        try fm.moveItem(at: updating, to: staged)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try fm.moveItem(at: staged, to: updating)

        for _ in 0..<100 where departures.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let leavingDeparture = try #require(departures.first { $0.app.bundleID == "com.test.leaving" })
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: leavingDeparture.app,
            bundleStillExists: leavingDeparture.bundleStillExists,
            installedBundleIDs: leavingDeparture.installedBundleIDs,
            removedByPurge: false
        ))
        for departure in departures where departure.app.bundleID == "com.test.updating" {
            #expect(!RemovedAppWatchPolicy.shouldOfferReview(
                for: departure.app,
                bundleStillExists: departure.bundleStillExists,
                installedBundleIDs: departure.installedBundleIDs,
                removedByPurge: false
            ))
        }
    }
}

@Suite("Removed-app handoff files")
struct RemovedAppHandoffTests {
    @Test
    func enqueueAndDrainRoundTripsInOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root
        defer { RemovedAppHandoff.root = previous }

        RemovedAppHandoff.enqueue(.init(path: "/Applications/A.app", bundleID: "com.a", name: "A"))
        RemovedAppHandoff.enqueue(.init(path: "/Applications/B.app", bundleID: "com.b", name: "B"))

        let drained = RemovedAppHandoff.drain()
        #expect(Set(drained.map(\.name)) == ["A", "B"])
        #expect(RemovedAppHandoff.drain().isEmpty)
    }

    @Test
    func ignoreExpiresAfterGrace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root
        defer { RemovedAppHandoff.root = previous }

        let path = "/Applications/Gone.app"
        RemovedAppHandoff.ignore(paths: [path])
        #expect(RemovedAppHandoff.isIgnored(path: path))
    }
}
