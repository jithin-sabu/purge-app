import Foundation
import Testing
@testable import Purge

/// An app on a drive goes through the same uninstall gate, which reads the
/// drive again at delete time, and never reaches the root helper: its move only
/// reaches the home folder's Trash (#99). The drives are folders in a stand-in
/// for `/Volumes`, the saved folder list is a temporary one, and the fake Trash
/// moves nothing.
@Suite("Apps on drives at delete time (#99)")
struct FileDeleterDriveAppTests {
    private struct Fixture {
        let base: URL
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var volumes: URL { base.appendingPathComponent("Volumes", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-drive-apps-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        }

        /// An app bundle at `relative` under `base`.
        func app(_ relative: String) throws -> URL {
            let bundle = base.appendingPathComponent(relative, isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let name = bundle.deletingPathExtension().lastPathComponent.lowercased()
            let info: NSDictionary = ["CFBundleIdentifier": "com.purgetest.\(name)"]
            info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            return bundle
        }

        func folder(_ relative: String) throws -> URL {
            let url = base.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// Records what the helper was asked to move, and moves it.
    private final class Helper: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String]] = []

        func move(_ urls: [URL]) -> PrivilegedMoveResult {
            lock.lock()
            requests.append(urls.map(\.standardizedFileURL.path))
            lock.unlock()
            return PrivilegedMoveResult(moved: urls, failed: [], indeterminate: [])
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    /// The error Purge's own move gets for a bundle owned by someone else.
    private static let noPermission: FileDeleter.Trasher = { _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
    }

    private func withDrives<T>(_ fixture: Fixture, _ body: () async throws -> T) async throws -> T {
        try await withTemporaryHandoffRoot {
            try await AppFolders.$volumes.withValue(fixture.volumes) {
                try await body()
            }
        }
    }

    // MARK: - Gate

    @Test("An app in a drive's Applications folder passes the uninstall gate")
    func driveAppIsEligible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Volumes/SSD/Applications/Photo/Luminar Neo.app")

        try await withDrives(fixture) {
            #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
        }
    }

    @Test("An app on a drive that now holds a whole Mac is refused")
    func driveThatChangedIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Volumes/SSD/Applications/Tool.app")
        try fixture.folder("Volumes/SSD/System")

        try await withDrives(fixture) {
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
        }
    }

    @Test("An app in an added folder passes only while the folder is on the list")
    func pickedFolderAppIsEligibleWhileListed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.folder("Volumes/SSD/Apps")
        let app = try fixture.app("Volumes/SSD/Apps/Tool.app")

        try await withDrives(fixture) {
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
            #expect(AppFolders.add(folder, home: fixture.home).refusal == nil)
            #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
            #expect(AppFolders.remove(path: folder.standardizedFileURL.path))
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
        }
    }

    @Test("An app elsewhere on a drive is still refused")
    func unlistedDriveAppIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Volumes/SSD/Projects/build/Tool.app")

        try await withDrives(fixture) {
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(app, home: fixture.home))
        }
    }

    // MARK: - Helper

    @Test("An app on another volume never goes to the helper, and its row says to use Finder")
    func appOnAnotherVolumeSkipsTheHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Volumes/SSD/Applications/Tool.app")
        let key = app.standardizedFileURL.path
        let helper = Helper()

        // `/dev` stands in for a home folder on another volume than the
        // bundle: no test can mount a real drive, and the check compares devices.
        let otherVolumeHome = URL(fileURLWithPath: "/dev", isDirectory: true)
        let report = try await withDrives(fixture) {
            try await FileDeleter(
                privilegedMover: { helper.move($0) },
                home: otherVolumeHome,
                trash: Self.noPermission,
                fullDiskAccessGranted: { true }
            ).deleteUserSelectedFiles(
                at: [app],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )
        }

        #expect(helper.calls.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.map(\.reason) == [.moveOnDriveInFinder])
        // Retry finishes the leftovers once the app is dragged out in Finder.
        #expect(report.failedItems.first?.reason.showsRetry == true)
    }

    @Test("The same app on the home folder's volume still goes to the helper")
    func appOnTheHomeVolumeUsesTheHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Volumes/SSD/Applications/Tool.app")
        let key = app.standardizedFileURL.path
        let helper = Helper()

        let report = try await withDrives(fixture) {
            try await FileDeleter(
                privilegedMover: { helper.move($0) },
                home: fixture.home,
                trash: Self.noPermission,
                fullDiskAccessGranted: { true }
            ).deleteUserSelectedFiles(
                at: [app],
                privilegedEligiblePaths: [key],
                privilegedBundlePaths: [key]
            )
        }

        #expect(helper.calls == [[key]])
        #expect(report.failedItems.isEmpty)
    }

    @Test("The root helper refuses an app on a drive")
    func helperRefusesDriveApps() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        for path in ["/Volumes/SSD/Applications/A.app", "/Volumes/SSD/Apps/V/A.app"] {
            #expect(!PurgeHelperConstants.isAllowedUninstallLocation(URL(fileURLWithPath: path), homeDirectory: home))
        }
    }
}
