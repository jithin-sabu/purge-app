import Foundation
import Testing
@testable import Purge

/// An app whose bundle won't move is held with its leftovers, and its row says why
/// (#299). The uninstaller runs through the real store with a fake Trash, a fake
/// helper, and no Full Disk Access. Every file lives in a temporary home, and the
/// store's helper switch is a fake, so no test registers the real helper.
@MainActor
@Suite("A held app says why it stayed")
struct LockedUninstallRetryTests {
    private let fm = FileManager.default

    private struct Fixture {
        let home: URL
        let bundle: URL
        let leftover: URL

        var app: InstalledApp {
            InstalledApp(name: "Example", bundleURL: bundle, bundleID: "com.purgetest.example", bundleSizeBytes: 4096, isRunning: false)
        }

        func plan() -> UninstallPlan {
            let safety = SafetyInfo(level: .medium, headline: "Example", explanation: "", recoverySteps: "", reinstallCommand: nil)
            return UninstallPlan(id: app.id, apps: [
                UninstallAppPlan(app: app, items: [
                    UninstallItem(path: bundle, sizeBytes: 4096, category: .bundle, safetyInfo: safety,
                                  matchReason: .appBundle, isSelected: true),
                    UninstallItem(path: leftover, sizeBytes: 512, category: .preferences, safetyInfo: safety,
                                  matchReason: .bundleID, isSelected: true)
                ])
            ])
        }
    }

    private func makeFixture() throws -> Fixture {
        let home = fm.temporaryDirectory
            .appendingPathComponent("LockedUninstallRetryTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let bundle = home.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.purgetest.example"]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        let leftover = home.appendingPathComponent("Library/Preferences/com.purgetest.example.plist")
        try fm.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 512).write(to: leftover)
        return Fixture(home: home, bundle: bundle, leftover: leftover)
    }

    /// The Trash refuses any app bundle with `bundleError`, by default the error a
    /// root-owned one gets, and takes everything else without touching the disk.
    /// With `bundleError` nil it takes the bundle too.
    private final class Trash: @unchecked Sendable {
        private let lock = NSLock()
        private var moved: [String] = []
        private var error: NSError? = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)

        var bundleError: NSError? {
            get { lock.lock(); defer { lock.unlock() }; return error }
            set { lock.lock(); error = newValue; lock.unlock() }
        }

        var trasher: FileDeleter.Trasher {
            { [self] url in
                if url.pathExtension == "app", let error = bundleError {
                    throw error
                }
                lock.lock()
                moved.append(url.standardizedFileURL.path)
                lock.unlock()
            }
        }

        var movedPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return moved
        }
    }

    /// Answers each request with whatever `answer` holds at the time.
    private final class Helper: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var reply: @Sendable (URL) -> PrivilegedMoveResult = { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], helperAvailable: false)
        }

        func answer(_ reply: @escaping @Sendable (URL) -> PrivilegedMoveResult) {
            lock.lock()
            self.reply = reply
            lock.unlock()
        }

        func move(_ urls: [URL]) -> PrivilegedMoveResult {
            lock.lock()
            calls += 1
            let reply = self.reply
            lock.unlock()
            return reply(urls[0])
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private final class Switch {
        var isOn = false
        var setupRequests = 0
    }

    private func makeStore(_ fixture: Fixture, scans: FakeScans, trash: Trash, helper: Helper, helperSwitch: Switch) -> PurgeStore {
        let deleter = FileDeleter(
            privilegedMover: { helper.move($0) },
            home: fixture.home,
            trash: trash.trasher,
            fullDiskAccessGranted: { false }
        )
        let store = scans.makeStore(fileDeleter: deleter)
        store.helperIsEnabled = { helperSwitch.isOn }
        store.enableHelper = { helperSwitch.setupRequests += 1 }
        store.installedApps = [fixture.app]
        return store
    }

    private func uninstall(_ store: PurgeStore, _ fixture: Fixture) async throws -> CleanFailureItem {
        try await withTemporaryHandoffRoot {
            await store.confirmUninstallPlan(fixture.plan())
        }
        let rows = store.manualDeletionSession?.failedItems ?? []
        return try #require(rows.first { $0.path == fixture.bundle.path })
    }

    @Test func withTheHelperOffTheHeldAppOffersSetup() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        let store = makeStore(fixture, scans: scans, trash: trash, helper: Helper(), helperSwitch: Switch())

        let row = try await uninstall(store, fixture)

        #expect(row.reason == .needsAdministrator)
        #expect(row.route == .lockedUninstall)
        // The app stayed, so nothing it left behind went either.
        #expect(trash.movedPaths.isEmpty)
    }

    /// The #303 case: every bundle stayed, so nothing moved. History still keeps
    /// the held app with its reason, and the completion screen lists it once.
    @Test func historyKeepsAHeldAppWithItsReason() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = makeStore(fixture, scans: scans, trash: Trash(), helper: Helper(), helperSwitch: Switch())

        _ = try await uninstall(store, fixture)

        let entry = try #require(CleanupHistoryStore.shared.archive.entries.first {
            $0.failedItems.contains { $0.path == fixture.bundle.path }
        })
        #expect(entry.deletedItems.isEmpty)
        #expect(entry.failedItems.map(\.failureReason) == [.needsAdministrator])
        #expect(entry.failedItems.map(\.sizeBytes) == [Int64(4096 + 512)])
        #expect(CleanupHistorySummaryRow(entry: entry).detailText == String(localized: "1 item couldn't be cleaned"))
        let rows = store.manualDeletionSession?.failedItems ?? []
        #expect(rows.filter { $0.path == fixture.bundle.path }.count == 1)
    }

    @Test func aStandardAccountThatCancelsTheDialogIsAskedForAPassword() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let helper = Helper()
        helper.answer { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], refusal: .notAdministrator)
        }
        let helperSwitch = Switch()
        helperSwitch.isOn = true
        let store = makeStore(fixture, scans: scans, trash: Trash(), helper: helper, helperSwitch: helperSwitch)

        let row = try await uninstall(store, fixture)

        #expect(row.reason == .needsAdministratorAccount)
        #expect(row.route == .lockedUninstall)
    }

    /// The reported case: setup is done, the tap tries again, and the bundle still
    /// won't move. The row now says so instead of staying as it was.
    @Test func aRetryThatStillFailsChangesTheRow() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        let helper = Helper()
        let helperSwitch = Switch()
        let store = makeStore(fixture, scans: scans, trash: trash, helper: helper, helperSwitch: helperSwitch)
        let held = try await uninstall(store, fixture)
        let session = try #require(store.manualDeletionSession)

        // First tap: the setup step, nothing else.
        #expect(await store.retryCleanFailure(held, session: session) == nil)
        #expect(helperSwitch.setupRequests == 1)
        #expect(session.failedItems.first { $0.id == held.id }?.reason == .needsAdministrator)

        // Approved now, but the helper can't move it.
        helperSwitch.isOn = true
        helper.answer { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], failureCodes: [url: Int(EACCES)])
        }
        let callsBefore = helper.callCount
        #expect(await store.retryCleanFailure(held, session: session) == nil)

        #expect(helper.callCount == callsBefore + 1)
        let row = try #require(session.failedItems.first { $0.id == held.id })
        #expect(row.reason == .unknown)
        #expect(row.route == .lockedUninstall)
        #expect(trash.movedPaths.isEmpty)
        #expect(fm.fileExists(atPath: fixture.leftover.path))
    }

    /// A standard account cancelled the administrator dialog. Retry asks the helper
    /// again, which shows the dialog again, and never runs setup (#314). Once an
    /// administrator approves, the whole app goes.
    @Test func aStandardAccountsRetryAsksTheHelperAgain() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        let helper = Helper()
        helper.answer { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], refusal: .notAdministrator)
        }
        let helperSwitch = Switch()
        helperSwitch.isOn = true
        let store = makeStore(fixture, scans: scans, trash: trash, helper: helper, helperSwitch: helperSwitch)
        let held = try await uninstall(store, fixture)
        #expect(held.reason == .needsAdministratorAccount)
        #expect(held.reason.showsRetry)
        let session = try #require(store.manualDeletionSession)

        helper.answer { url in
            try? FileManager.default.removeItem(at: url)
            return PrivilegedMoveResult(moved: [url], failed: [], indeterminate: [])
        }
        let callsBefore = helper.callCount
        let moved = try await withTemporaryHandoffRoot {
            await store.retryCleanFailure(held, session: session)
        }

        #expect(helper.callCount == callsBefore + 1)
        #expect(helperSwitch.setupRequests == 0)
        let movedBytes: Int64 = try #require(moved)
        #expect(movedBytes == 4096 + 512)
        #expect(!session.failedItems.contains { $0.id == held.id })
        #expect(trash.movedPaths == [fixture.leftover.path])
    }

    /// Once the helper moves the bundle, the leftovers held with it go too and the
    /// row is resolved.
    @Test func aRetryTheHelperCompletesRemovesTheWholeApp() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        let helper = Helper()
        let helperSwitch = Switch()
        let store = makeStore(fixture, scans: scans, trash: trash, helper: helper, helperSwitch: helperSwitch)
        let held = try await uninstall(store, fixture)
        let session = try #require(store.manualDeletionSession)

        helperSwitch.isOn = true
        helper.answer { url in
            try? FileManager.default.removeItem(at: url)
            return PrivilegedMoveResult(moved: [url], failed: [], indeterminate: [])
        }
        let moved = try await withTemporaryHandoffRoot {
            await store.retryCleanFailure(held, session: session)
        }

        let movedBytes: Int64 = try #require(moved)
        #expect(movedBytes == 4096 + 512)
        #expect(!session.failedItems.contains { $0.id == held.id })
        #expect(trash.movedPaths == [fixture.leftover.path])
        #expect(store.installedApps.isEmpty)
    }

    /// With the helper off, a held app that was only in use says so, and Retry tries
    /// the move again rather than running setup the row never offered.
    @Test func withTheHelperOffAnInUseAppRetriesTheMove() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        trash.bundleError = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: nil)
        let helperSwitch = Switch()
        let store = makeStore(fixture, scans: scans, trash: trash, helper: Helper(), helperSwitch: helperSwitch)
        let held = try await uninstall(store, fixture)
        let session = try #require(store.manualDeletionSession)
        #expect(held.reason == .inUse)

        // The user quits the app and taps Retry.
        trash.bundleError = nil
        let moved = try await withTemporaryHandoffRoot {
            await store.retryCleanFailure(held, session: session)
        }

        #expect(helperSwitch.setupRequests == 0)
        let movedBytes: Int64 = try #require(moved)
        #expect(movedBytes == 4096 + 512)
        #expect(!session.failedItems.contains { $0.id == held.id })
        #expect(trash.movedPaths == [fixture.bundle.path, fixture.leftover.path])
        #expect(store.installedApps.isEmpty)
    }

    /// A held app the user removed in Finder: Retry finishes the uninstall with the
    /// leftovers held with it, and asks for no setup.
    @Test func aRetryAfterFinderRemovedTheAppTakesItsLeftovers() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = Trash()
        let helper = Helper()
        let helperSwitch = Switch()
        let store = makeStore(fixture, scans: scans, trash: trash, helper: helper, helperSwitch: helperSwitch)
        let held = try await uninstall(store, fixture)
        let session = try #require(store.manualDeletionSession)
        #expect(held.reason == .needsAdministrator)

        try fm.removeItem(at: fixture.bundle)
        let callsBefore = helper.callCount
        let moved = try await withTemporaryHandoffRoot {
            await store.retryCleanFailure(held, session: session)
        }

        #expect(helperSwitch.setupRequests == 0)
        #expect(helper.callCount == callsBefore)
        let movedBytes: Int64 = try #require(moved)
        #expect(movedBytes == 512)
        #expect(!session.failedItems.contains { $0.id == held.id })
        #expect(trash.movedPaths == [fixture.leftover.path])
        #expect(store.installedApps.isEmpty)
    }

    /// Finder is offered only for a whole app that Finder can still remove: not one
    /// waiting on setup, protected by macOS, or kept back for safety, and never for
    /// a plain file row.
    @Test func onlyAHeldAppFinderCanRemoveOffersFinder() {
        func offers(_ reason: CleanFailureReason, route: DeletionRoute = .lockedUninstall) -> Bool {
            CleanFailureItem(path: "/Applications/Example.app", displayName: "Example", reason: reason, route: route)
                .offersFinderRemoval
        }
        #expect(offers(.unknown))
        #expect(offers(.inUse))
        #expect(offers(.needsAdministratorAccount))
        #expect(!offers(.needsAdministrator))
        #expect(!offers(.systemProtected))
        #expect(!offers(.safetySkipped))
        #expect(!offers(.unknown, route: .userSelected(isAIModel: false, privilegedEligible: true)))
    }
}
