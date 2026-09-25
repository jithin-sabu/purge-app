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

    /// Finder renames a trashed bundle when an older copy already sits there. The
    /// copy that counts is the one with the departed bundle's file number, never a
    /// stale one that only shares its name.
    @Test
    func trashedCopyIsFoundByFileNumberNotName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-trash-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stale = trash.appendingPathComponent("Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        let bundle = apps.appendingPathComponent("Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let number = try #require(RemovedAppWatchPolicy.fileNumber(atPath: bundle.path))

        let renamed = trash.appendingPathComponent("Rectangle 10.23.45.app", isDirectory: true)
        try fm.moveItem(at: bundle, to: renamed)

        let found = RemovedAppWatchPolicy.trashedCopy(fileNumber: number, in: trash)
        #expect(found?.lastPathComponent == renamed.lastPathComponent)
        #expect(RemovedAppWatchPolicy.trashedCopy(fileNumber: nil, in: trash) == nil)
    }

    /// A handle on a bundle reports where it went. Only the same file counts: a
    /// deleted bundle's handle still names its old path, which may hold nothing
    /// or a replacement by then.
    @Test
    func departureKindFollowsTheBundleNotItsName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-kind-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        for folder in [apps, trash, desktop] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        func bundle(_ name: String) throws -> (URL, UInt64) {
            let url = apps.appendingPathComponent("\(name).app", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, try #require(RemovedAppWatchPolicy.fileNumber(atPath: url.path)))
        }

        let (trashed, trashedNumber) = try bundle("Trashed")
        let inTrash = trash.appendingPathComponent("Trashed 10.23.45.app")
        try fm.moveItem(at: trashed, to: inTrash)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: inTrash.path, fileNumber: trashedNumber) == .trashed)

        let (moved, movedNumber) = try bundle("Moved")
        let onDesktop = desktop.appendingPathComponent("Moved.app")
        try fm.moveItem(at: moved, to: onDesktop)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: onDesktop.path, fileNumber: movedNumber) == .movedElsewhere)

        let (deleted, deletedNumber) = try bundle("Deleted")
        try fm.removeItem(at: deleted)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: deleted.path, fileNumber: deletedNumber) == .deleted)

        let (replaced, replacedNumber) = try bundle("Replaced")
        try fm.removeItem(at: replaced)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: replaced.path, fileNumber: replacedNumber) == .deleted)

        #expect(RemovedAppWatchPolicy.departureKind(currentPath: nil, fileNumber: 1) == .deleted)
    }

    @Test
    func followDecisionReportsDeletionsOnceQuietAndDropsMovesAndReturns() {
        let timing = RemovedAppWatchPolicy.FollowTiming.standard
        func decide(
            _ kind: RemovedAppWatchPolicy.DepartureKind,
            back: Bool = false,
            departure: Duration = .seconds(1),
            deleted: Duration? = nil,
            activity: Duration = .seconds(0)
        ) -> RemovedAppWatchPolicy.FollowDecision {
            RemovedAppWatchPolicy.followDecision(
                kind: kind,
                appIsBack: back,
                sinceDeparture: departure,
                sinceDeleted: deleted,
                sinceActivity: activity,
                timing: timing
            )
        }
        // `rm`: reported once the roots have been quiet for the quiet period.
        #expect(decide(.deleted, deleted: .seconds(1), activity: .seconds(1)) == .keepFollowing)
        #expect(decide(.deleted, deleted: .seconds(2), activity: .seconds(2)) == .report)
        // An installer still writing keeps it waiting, but never past the cap.
        #expect(decide(.deleted, deleted: .seconds(29), activity: .milliseconds(100)) == .keepFollowing)
        #expect(decide(.deleted, deleted: .seconds(30), activity: .milliseconds(100)) == .report)
        // Moved: followed for the window, then dropped as a move.
        #expect(decide(.movedElsewhere, departure: .seconds(59)) == .keepFollowing)
        #expect(decide(.movedElsewhere, departure: .seconds(60)) == .drop)
        // Trashed later (from the Desktop, say): reported.
        #expect(decide(.trashed, departure: .seconds(20)) == .report)
        // The update landed or the app was put back: never reported.
        #expect(decide(.deleted, back: true, deleted: .seconds(5), activity: .seconds(5)) == .drop)
        #expect(decide(.trashed, back: true) == .drop)
    }

    // MARK: Review decision

    @Test
    func offersReviewForAnAppThatIsReallyGone() {
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: ["com.other.app"],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    @Test
    func updateThatPutTheBundleBackIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: true,
            installedBundleIDs: [],
            otherCopyExists: false,
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
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    @Test
    func purgeOwnUninstallIsNotReviewedTwice() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: true
        ))
    }

    @Test
    func appsWithoutAnIdentifierOrPurgeItselfAreSkipped() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(bundleID: nil),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: false
        ))
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(name: "Purge", bundlePath: "/Applications/Purge.app", bundleID: "io.getpurge.app"),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    /// Dragged to the Desktop, on an external drive, or set aside by an updater:
    /// Launch Services still knows a live copy, so its data is still in use.
    @Test
    func aLiveCopyElsewhereIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: true,
            removedByPurge: false
        ))
    }

    @Test
    func otherCopiesInTheTrashOrAtTheOldPathDoNotCount() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-copies-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let desktopCopy = root.appendingPathComponent("Desktop/Rectangle.app", isDirectory: true)
        let trashedCopy = root.appendingPathComponent(".Trash/Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: desktopCopy, withIntermediateDirectories: true)
        try fm.createDirectory(at: trashedCopy, withIntermediateDirectories: true)
        let app = makeApp()

        #expect(RemovedAppWatchPolicy.countsAsOtherCopy(desktopCopy, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(trashedCopy, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(app.bundleURL, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(
            root.appendingPathComponent("Missing/Rectangle.app"), of: app
        ))
        #expect(RemovedAppWatchPolicy.isInTrash(path: "/Volumes/Backup/.Trashes/501/Rectangle.app"))
        #expect(RemovedAppWatchPolicy.isInTrash(path: "/Users/x/Library/Mobile Documents/.Trash/Rectangle.app"))
    }

    // MARK: Records

    /// A record is a file any process running as the user can write, so only one
    /// the watcher could have produced is acted on.
    @Test
    func onlyRecordsTheWatcherCouldHaveWrittenAreValid() {
        let roots = ["/Applications", "/Users/x/Applications"]
        func valid(_ path: String, _ id: String = "com.knollsoft.Rectangle", _ name: String = "Rectangle") -> Bool {
            RemovedAppWatchPolicy.isValidRecord(path: path, bundleID: id, name: name, roots: roots)
        }
        #expect(valid("/Applications/Rectangle.app"))
        #expect(valid("/Applications/Vendor/Rectangle.app"))
        #expect(valid("/Users/x/Applications/Rectangle.app"))

        #expect(!valid("/Applications/A/B/Rectangle.app"))
        #expect(!valid("/Library/LaunchDaemons/Rectangle.app"))
        #expect(!valid("/Applications/../Library/Rectangle.app"))
        #expect(!valid("/Applications/Rectangle"))
        #expect(!valid("/Applications/Rectangle.app", "no-dots"))
        #expect(!valid("/Applications/Rectangle.app", "com.x/../y"))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", ""))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", "Line\nbreak"))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", String(repeating: "a", count: 200)))
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
            survivors: [],
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.category) == [.preferences, .applicationSupport])
        #expect(rows.map(\.isSelected) == [true, false])
    }

    /// The review opens unprompted, so nothing outside the home folder starts
    /// ticked, even an identifier match. Those are the paths that can need the
    /// administrator helper.
    @Test
    func reviewNeverPreselectsSystemLevelLeftovers() {
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Library/LaunchDaemons/com.knollsoft.Rectangle.plist", category: .launchDaemons, reason: .bundleID),
                item("/Users/x/Library/Caches/com.knollsoft.Rectangle", category: .caches, reason: .bundleID)
            ],
            owner: makeApp(),
            survivors: [],
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.isSelected) == [false, true])
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
            survivors: [survivor],
            home: URL(fileURLWithPath: "/Users/x")
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

    /// A bundle an updater replaced at the same path has a new file number, so it
    /// is read again instead of being described by the copy it replaced.
    @Test
    func indexRereadsABundleSwappedInPlace() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let bundle = try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let before = ApplicationsFolderWatcher.index(roots: [root], reusing: .init())

        let staged = try makeBundle(in: try makeRoot(), name: "Alpha", bundleID: "com.test.alpha2")
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        try fm.removeItem(at: bundle)
        try fm.moveItem(at: staged, to: bundle)

        let after = ApplicationsFolderWatcher.index(roots: [root], reusing: before)
        #expect(after.bundleIDs == ["com.test.alpha2"])
        #expect(after.fileNumbers[bundle.standardizedFileURL.path] != before.fileNumbers[bundle.standardizedFileURL.path])
    }

    /// End to end through FSEvents: a bundle that leaves is reported at once, well
    /// inside the three seconds the old settle delay waited, and carries the file
    /// number its Trash copy can be found by. A bundle that comes back shows up in
    /// the next index, which is what withdraws a review opened during an update.
    @Test(.timeLimit(.minutes(1)))
    func reportsADepartureAtOnceAndSeesTheAppComeBack() async throws {
        let root = try makeRoot()
        let elsewhere = try makeRoot()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: elsewhere)
        }
        let leaving = try makeBundle(in: root, name: "Leaving", bundleID: "com.test.leaving")
        let leavingNumber = RemovedAppWatchPolicy.fileNumber(atPath: leaving.path)

        let watcher = ApplicationsFolderWatcher(roots: [root])
        var departures: [ApplicationsFolderWatcher.Departure] = []
        var indexes: [ApplicationsFolderWatcher.Index] = []
        watcher.onDeparture = { departures.append($0) }
        watcher.onChange = { indexes.append($0) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 1)
        // FSEvents needs a moment after the stream starts before it reports.
        try await Task.sleep(nanoseconds: 500_000_000)

        let movedAt = Date()
        let moved = elsewhere.appendingPathComponent("Leaving.app")
        try fm.moveItem(at: leaving, to: moved)
        for _ in 0..<100 where departures.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let departure = try #require(departures.first)
        #expect(Date().timeIntervalSince(movedAt) < 1.5)
        #expect(departure.app.bundleID == "com.test.leaving")
        // The id must not drift once the bundle is gone, or the ignore list and the
        // record path stop matching it.
        #expect(departure.app.id == leaving.standardizedFileURL.path)
        #expect(departure.fileNumber == leavingNumber)
        #expect(!departure.bundleStillExists)
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: departure.app,
            bundleStillExists: departure.bundleStillExists,
            installedBundleIDs: departure.installedBundleIDs,
            otherCopyExists: false,
            removedByPurge: false
        ))

        let seen = indexes.count
        try fm.moveItem(at: moved, to: leaving)
        for _ in 0..<100 where !indexes.dropFirst(seen).contains(where: { $0.bundleIDs.contains("com.test.leaving") }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(indexes.dropFirst(seen).contains { $0.bundleIDs.contains("com.test.leaving") })
    }

    /// With destination tracking (the background agent), on compressed timings:
    /// a drag to the Trash is reported at once; a deletion once the roots go quiet;
    /// a copy moved and left alone never; a moved copy that is then trashed, or
    /// deleted the way `brew uninstall` purges the Caskroom, when that happens; and
    /// a `brew upgrade` style swap never.
    @Test(.timeLimit(.minutes(1)))
    func trashIsReportedAtOnceAndEverythingElseIsFollowed() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outside)
        }
        let trash = outside.appendingPathComponent(".Trash", isDirectory: true)
        let desktop = outside.appendingPathComponent("Desktop", isDirectory: true)
        let caskroom = outside.appendingPathComponent("Caskroom", isDirectory: true)
        for folder in [trash, desktop, caskroom] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let trashed = try makeBundle(in: root, name: "Trashed", bundleID: "com.test.trashed")
        let moved = try makeBundle(in: root, name: "Moved", bundleID: "com.test.moved")
        let movedThenTrashed = try makeBundle(in: root, name: "Later", bundleID: "com.test.later")
        let uninstalled = try makeBundle(in: root, name: "Uninstalled", bundleID: "com.test.uninstalled")
        let deleted = try makeBundle(in: root, name: "Deleted", bundleID: "com.test.deleted")
        let upgraded = try makeBundle(in: root, name: "Upgraded", bundleID: "com.test.upgraded")

        let timing = RemovedAppWatchPolicy.FollowTiming(
            quietPeriod: .milliseconds(500),
            maxDeletedWait: .seconds(5),
            movedFollowWindow: .seconds(2),
            pollInterval: .milliseconds(50)
        )
        let watcher = ApplicationsFolderWatcher(roots: [root], tracksDestinations: true, timing: timing)
        var departures: [(at: Date, departure: ApplicationsFolderWatcher.Departure)] = []
        watcher.onDeparture = { departures.append((Date(), $0)) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.count < 6 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 6)
        try await Task.sleep(nanoseconds: 500_000_000)

        func reported(_ id: String) -> (at: Date, departure: ApplicationsFolderWatcher.Departure)? {
            departures.first { $0.departure.app.bundleID == id }
        }
        func waitFor(_ id: String, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while reported(id) == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let start = Date()
        try fm.moveItem(at: trashed, to: trash.appendingPathComponent("Trashed 10.23.45.app"))
        let onDesktop = desktop.appendingPathComponent("Later.app")
        try fm.moveItem(at: moved, to: desktop.appendingPathComponent("Moved.app"))
        try fm.moveItem(at: movedThenTrashed, to: onDesktop)
        let inCaskroom = caskroom.appendingPathComponent("Uninstalled.app")
        try fm.moveItem(at: uninstalled, to: inCaskroom)
        try fm.removeItem(at: deleted)
        // The upgrade: set the old copy aside, install the new one, drop the old.
        let backup = caskroom.appendingPathComponent("Upgraded.app")
        try fm.moveItem(at: upgraded, to: backup)
        try makeBundle(in: root, name: "Upgraded", bundleID: "com.test.upgraded")
        try fm.removeItem(at: backup)

        try await waitFor("com.test.trashed", seconds: 1)
        let trashReport = try #require(reported("com.test.trashed"))
        #expect(trashReport.departure.kind == .trashed)
        #expect(trashReport.at.timeIntervalSince(start) < 0.6)
        #expect(reported("com.test.deleted") == nil)

        try await waitFor("com.test.deleted", seconds: 3)
        let deleteReport = try #require(reported("com.test.deleted"))
        #expect(deleteReport.departure.kind == .deleted)
        #expect(deleteReport.at.timeIntervalSince(start) >= 0.5)

        // Well inside the follow window, the Desktop copy goes to the Trash and
        // Homebrew purges its Caskroom copy. Both count from that moment.
        #expect(reported("com.test.later") == nil)
        #expect(reported("com.test.uninstalled") == nil)
        let laterMovedAt = Date()
        try fm.moveItem(at: onDesktop, to: trash.appendingPathComponent("Later.app"))
        try fm.removeItem(at: inCaskroom)
        try await waitFor("com.test.later", seconds: 1)
        try await waitFor("com.test.uninstalled", seconds: 2)
        let laterReport = try #require(reported("com.test.later"))
        #expect(laterReport.departure.kind == .trashed)
        #expect(laterReport.at.timeIntervalSince(laterMovedAt) < 0.5)
        #expect(reported("com.test.uninstalled")?.departure.kind == .deleted)

        // Past the follow window: the copy left on the Desktop was a move, and the
        // upgraded app came back, so neither was ever reported.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        #expect(reported("com.test.moved") == nil)
        #expect(reported("com.test.upgraded") == nil)
    }
}

@Suite("Removed-app handoff files", .serialized)
struct RemovedAppHandoffTests {
    private func withTemporaryRoot(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root
        defer { RemovedAppHandoff.root = previous }
        try body()
    }

    /// Reading leaves records in place, so a review that has to wait for
    /// onboarding or Full Disk Access is not lost. Discarding removes one.
    @Test
    func pendingRecordsStayUntilDiscarded() throws {
        try withTemporaryRoot {
            RemovedAppHandoff.enqueue(.init(path: "/Applications/A.app", bundleID: "com.a", name: "A", fileNumber: 7, removedAt: Date()))
            RemovedAppHandoff.enqueue(.init(path: "/Applications/B.app", bundleID: "com.b", name: "B"))

            #expect(Set(RemovedAppHandoff.pending().map(\.name)) == ["A", "B"])
            #expect(RemovedAppHandoff.pending().count == 2)
            #expect(RemovedAppHandoff.pending().first { $0.name == "A" }?.fileNumber == 7)

            RemovedAppHandoff.discard(path: "/Applications/A.app")
            #expect(RemovedAppHandoff.pending().map(\.name) == ["B"])

            RemovedAppHandoff.clearPending()
            #expect(RemovedAppHandoff.pending().isEmpty)
        }
    }

    /// A record that waited more than a week is dropped rather than reviewed.
    @Test
    func oldRecordsExpire() throws {
        try withTemporaryRoot {
            let longAgo = Date().addingTimeInterval(-RemovedAppWatchPolicy.recordLifetime - 60)
            RemovedAppHandoff.enqueue(.init(path: "/Applications/Old.app", bundleID: "com.old", name: "Old", removedAt: longAgo))
            RemovedAppHandoff.enqueue(.init(path: "/Applications/New.app", bundleID: "com.new", name: "New", removedAt: Date()))
            #expect(RemovedAppHandoff.pending().map(\.name) == ["New"])
        }
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
