import Foundation
import Testing
@testable import Purge

/// The uninstaller's last resort: an item whose ordinary move failed goes to the
/// root helper, but only when the uninstall planner marked it and macOS gave no
/// reason for the failure (#189), or, for an app the user chose, after any
/// permission error (#299). The helper is a fake that records what it was
/// asked to move, every file lives in a temporary home, and the fake Trash moves
/// nothing (#171).
@Suite("FileDeleter hands a stuck uninstall item to the helper")
struct FileDeleterPrivilegedFallbackTests {
    /// A temporary home with leftovers in `Library/Preferences`, which the uninstall
    /// gate admits.
    private struct Home {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purgetest-helper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func leftover(_ name: String) throws -> URL {
            let file = url.appendingPathComponent("Library/Preferences/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: 512).write(to: file)
            return file
        }

        /// An app bundle in `~/Applications`, which the uninstall gate admits.
        func app(_ name: String) throws -> URL {
            let bundle = url.appendingPathComponent("Applications/\(name).app", isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": "com.purgetest.\(name.lowercased())"]
            info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            return bundle
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The error Purge's own move gets for a root-owned bundle, measured on macOS 27
    /// for #299. A locked bundle gets the same one.
    private static let noPermission: FileDeleter.Trasher = { _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
    }

    private static func setLocked(_ url: URL, _ locked: Bool) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        var target = url
        try target.setResourceValues(values)
    }

    /// Records each request and answers it with `answer`.
    private final class Helper: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String]] = []
        private let answer: @Sendable ([URL]) -> PrivilegedMoveResult

        init(_ answer: @escaping @Sendable ([URL]) -> PrivilegedMoveResult) {
            self.answer = answer
        }

        func move(_ urls: [URL]) -> PrivilegedMoveResult {
            lock.lock()
            requests.append(urls.map(\.standardizedFileURL.path))
            lock.unlock()
            return answer(urls)
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func deleter(
        home: Home,
        helper: Helper,
        trash: @escaping FileDeleter.Trasher,
        fullDiskAccess: Bool = true
    ) -> FileDeleter {
        FileDeleter(
            privilegedMover: { helper.move($0) },
            home: home.url,
            trash: trash,
            fullDiskAccessGranted: { fullDiskAccess }
        )
    }

    @Test func aMoveTheHelperMadeCountsAsMovedToTheTrash() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.leftover("com.purgetest.locked.plist")
        let key = leftover.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: [], ownershipIncomplete: $0) }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [leftover],
            pathToDisplayName: [key: "Locked Preferences"],
            pathToExpectedSizeBytes: [key: 512],
            privilegedEligiblePaths: [key]
        )

        #expect(helper.calls == [[key]])
        #expect(report.failedItems.isEmpty)
        #expect(report.bytesMovedToTrash == 512)
        let row = try #require(report.deletedItems.first)
        #expect(row.path == leftover.path)
        #expect(row.displayName == "Locked Preferences")
        #expect(row.movedToTrash)
        // The helper could not hand the item back, so emptying the Trash may ask
        // for a password, and the result says so.
        #expect(report.ownershipWarningPaths == [leftover.path])
    }

    /// The helper is set up and tried, and the item is still there: a real failure
    /// with Retry, not one-time setup again.
    @Test func aMoveTheHelperTriedAndFailedKeepsItsReason() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.leftover("com.purgetest.stuck.plist")
        let key = leftover.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let helper = Helper { PrivilegedMoveResult(moved: [], failed: $0, indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [leftover],
            pathToExpectedSizeBytes: [key: 512],
            privilegedEligiblePaths: [key]
        )

        #expect(helper.calls == [[key]])
        #expect(report.deletedItems.isEmpty)
        let failed = try #require(report.failedItems.first)
        #expect(failed.reason == .unknown)
        #expect(failed.reason.showsRetry)
    }

    /// The helper timed out. An item gone from its place did move and is credited;
    /// one still there keeps its failure.
    @Test func anUnsettledHelperMoveCountsOnlyOnceTheItemIsGone() async throws {
        let home = try Home()
        defer { home.remove() }
        let gone = try home.leftover("com.purgetest.gone.plist")
        let stays = try home.leftover("com.purgetest.stays.plist")
        let keys = [gone, stays].map(\.standardizedFileURL.path)
        let trash = FakeTrash()
        trash.failNextCalls(2)
        let helper = Helper { urls in
            // It moved one before the request timed out.
            try? FileManager.default.removeItem(at: gone)
            return PrivilegedMoveResult(moved: [], failed: [], indeterminate: urls)
        }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [gone, stays],
            pathToExpectedSizeBytes: [keys[0]: 512, keys[1]: 512],
            privilegedEligiblePaths: Set(keys)
        )

        #expect(helper.calls == [keys])
        #expect(report.deletedItems.map(\.path) == [gone.path])
        #expect(report.bytesMovedToTrash == 512)
        #expect(report.failedItems.map(\.path) == [stays.path])
        #expect(report.failedItems.first?.reason == .unknown)
    }

    /// Only a path the planner marked, whose move failed for no reason macOS gave,
    /// goes to the helper. An item in use is never retried as root, and an unmarked
    /// one never reaches the helper however its move fails.
    @Test func onlyMarkedPathsWithAnUnexplainedFailureReachTheHelper() async throws {
        let home = try Home()
        defer { home.remove() }
        let marked = try home.leftover("com.purgetest.marked.plist")
        let unmarked = try home.leftover("com.purgetest.unmarked.plist")
        let inUse = try home.leftover("com.purgetest.inuse.plist")
        let markedKey = marked.standardizedFileURL.path
        let inUseKey = inUse.standardizedFileURL.path
        let inUseName = inUse.lastPathComponent
        // Every ordinary move fails: the one in use says so, the others say nothing.
        let trash: FileDeleter.Trasher = { url in
            let code = url.lastPathComponent == inUseName ? NSFileLockingError : NSFileWriteUnknownError
            throw NSError(domain: NSCocoaErrorDomain, code: code, userInfo: nil)
        }
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: trash).deleteUserSelectedFiles(
            at: [marked, unmarked, inUse],
            privilegedEligiblePaths: [markedKey, inUseKey]
        )

        #expect(helper.calls == [[markedKey]])
        #expect(report.deletedItems.map(\.path) == [marked.path])
        #expect(report.failedItems.first { $0.path == unmarked.path }?.reason == .unknown)
        #expect(report.failedItems.first { $0.path == inUse.path }?.reason == .inUse)
        #expect(report.failedItems.count == 2)
    }

    /// The reported case (#299): no Full Disk Access, so the permission error reads
    /// as needing it, but the app the user chose still goes to the helper, which
    /// moves a root-owned bundle without it.
    @Test func aChosenBundleReachesTheHelperWithoutFullDiskAccess() async throws {
        let home = try Home()
        defer { home.remove() }
        let bundle = try home.app("Locked")
        let key = bundle.standardizedFileURL.path
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(
                at: [bundle],
                pathToExpectedSizeBytes: [key: 2048],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )

        #expect(helper.calls == [[key]])
        #expect(report.failedItems.isEmpty)
        #expect(report.deletedItems.map(\.path) == [bundle.path])
        #expect(report.bytesMovedToTrash == 2048)
    }

    /// The same error on a leftover keeps its reason and never reaches the helper:
    /// it may sit in a privacy-protected folder, which root must not get around.
    @Test func aLeftoverWithTheSameErrorNeverReachesTheHelper() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.leftover("com.purgetest.private.plist")
        let key = leftover.standardizedFileURL.path
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(
                at: [leftover],
                privilegedEligiblePaths: [key]
            )

        #expect(helper.calls.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.map(\.reason) == [.needsFullDiskAccess])
    }

    /// A leftover a caller wrongly lists as a bundle still never reaches the helper
    /// on that error. The helper would take a container folder, so the check on what
    /// is really an app bundle sits here, not only in each caller.
    @Test func aContainerListedAsABundleNeverReachesTheHelper() async throws {
        let home = try Home()
        defer { home.remove() }
        let container = home.url.appendingPathComponent("Library/Containers/com.purgetest.x", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let key = container.standardizedFileURL.path
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(
                at: [container],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )

        #expect(helper.calls.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.map(\.reason) == [.needsFullDiskAccess])
    }

    /// A locked bundle fails the same way as a root-owned one. It is named as
    /// protected and never sent, since the helper's move would fail too.
    @Test func aLockedBundleIsProtectedAndNeverSent() async throws {
        let home = try Home()
        defer { home.remove() }
        let bundle = try home.app("Immutable")
        try Self.setLocked(bundle, true)
        defer { try? Self.setLocked(bundle, false) }
        let key = bundle.standardizedFileURL.path
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(
                at: [bundle],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )

        #expect(helper.calls.isEmpty)
        #expect(report.failedItems.map(\.reason) == [.systemProtected])
    }

    /// Without Full Disk Access and with the helper not set up, a chosen bundle
    /// offers the one-time setup, as it already did with Full Disk Access.
    @Test func aBundleWithoutTheHelperOffersSetupWithoutFullDiskAccess() async throws {
        let home = try Home()
        defer { home.remove() }
        let bundle = try home.app("NoHelper")
        let key = bundle.standardizedFileURL.path
        let helper = Helper { PrivilegedMoveResult(moved: [], failed: $0, indeterminate: [], helperAvailable: false) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(
                at: [bundle],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )

        #expect(helper.calls == [[key]])
        #expect(report.failedItems.map(\.reason) == [.needsAdministrator])
    }

    /// One bundle the helper tried and left, with the answer `result` gives it.
    private func reasonAfterHelper(
        _ name: String,
        result: @escaping @Sendable (URL) -> PrivilegedMoveResult
    ) async throws -> CleanFailureReason? {
        let home = try Home()
        defer { home.remove() }
        let bundle = try home.app(name)
        let key = bundle.standardizedFileURL.path
        let helper = Helper { urls in result(urls[0]) }

        let report = try await deleter(home: home, helper: helper, trash: Self.noPermission, fullDiskAccess: false)
            .deleteUserSelectedFiles(at: [bundle], privilegedEligiblePaths: [key], privilegedBundlePaths: [key])
        return report.failedItems.first?.reason
    }

    /// No administrator approved a standard account's request (#182, #314). The row
    /// says it takes an administrator's password, and its Retry shows the dialog again.
    @Test func aStandardAccountWithoutApprovalIsAskedForAPassword() async throws {
        let reason = try await reasonAfterHelper("Refused") { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], refusal: .notAdministrator)
        }
        #expect(reason == .needsAdministratorAccount)
        #expect(reason?.showsRetry == true)
        #expect(reason?.retryTitle == String(localized: "Enter Password"))
    }

    /// The helper couldn't ask an administrator at all (#314). That is no reason the
    /// user can act on, so the row reads as unknown and Retry tries again.
    @Test func aHelperThatCannotAskReadsAsUnknown() async throws {
        let reason = try await reasonAfterHelper("NoApproval") { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], refusal: .approvalUnavailable)
        }
        #expect(reason == .unknown)
    }

    @Test func aBundleInUseSaysSo() async throws {
        let reason = try await reasonAfterHelper("Busy") { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], failureCodes: [url: Int(EBUSY)])
        }
        #expect(reason == .inUse)
    }

    /// An EPERM names macOS protection only when the flags on disk say so.
    @Test func aPermissionErrorFromTheHelperClaimsProtectionOnlyForAFlaggedBundle() async throws {
        let plain = try await reasonAfterHelper("Plain") { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [], failureCodes: [url: Int(EPERM)])
        }
        #expect(plain == .unknown)
        #expect(FileDeleter.reasonAfterHelperFailure(path: "/nonexistent/Locked.app", code: Int(EPERM), refusal: .accepted) == .unknown)
    }

    /// The bundle's first error read as needing Full Disk Access. After the helper
    /// tried, that is never the reason shown, timed out or not.
    @Test func aBundleTheHelperLeftNeverAsksForFullDiskAccess() async throws {
        let failed = try await reasonAfterHelper("Failed") { url in
            PrivilegedMoveResult(moved: [], failed: [url], indeterminate: [])
        }
        let timedOut = try await reasonAfterHelper("TimedOut") { url in
            PrivilegedMoveResult(moved: [], failed: [], indeterminate: [url])
        }
        #expect(failed == .unknown)
        #expect(timedOut == .unknown)
    }
}
