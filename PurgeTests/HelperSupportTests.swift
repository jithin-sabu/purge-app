import Darwin
import Foundation
import Testing
@testable import Purge

/// Covers the code the root helper shares with the app. The helper itself runs as
/// root and cannot be driven from a test, so these pin the two facts it relies on.
@Suite("Privileged helper support")
struct HelperSupportTests {
    // MARK: Search-only directory access

    /// A throwaway folder in the test host's temporary directory, never a real
    /// user folder. Permissions are restored before removal.
    private final class Sandbox {
        let root: URL

        init() throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("HelperSupportTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The temporary directory lives under /var, a symlink to /private/var, and
            // the helper refuses every symlinked component. Use the real path, as a home
            // folder like /Users/name already is. `realpath` keeps /private, which
            // Foundation's `resolvingSymlinksInPath` strips off again.
            guard let real = realpath(folder.path, nil) else { throw CocoaError(.fileNoSuchFile) }
            defer { free(real) }
            root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        }

        deinit {
            if let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in items {
                    chmod(url.path, 0o700)
                }
            }
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Opens a folder that can be passed through but not read, and moves an item into it")
    func opensUnreadableFolderAndMovesIntoIt() throws {
        let sandbox = try Sandbox()
        // Stands in for ~/.Trash under privacy protection: no permission to list it,
        // but permission to pass through and add to it.
        let trash = sandbox.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let item = sandbox.root.appendingPathComponent("Item.app", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        #expect(chmod(trash.path, 0o300) == 0)

        // The old read-only open fails on such a folder, so this test exercises the fix.
        let readOnly = open(trash.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(readOnly < 0)
        if readOnly >= 0 { close(readOnly) }

        let trashFD = try #require(HelperDirectory.openWithoutFollowingSymlinks(trash))
        defer { close(trashFD) }
        var info = stat()
        #expect(fstat(trashFD, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect(info.st_uid == getuid())

        let parentFD = try #require(HelperDirectory.openWithoutFollowingSymlinks(sandbox.root))
        defer { close(parentFD) }
        let moved = renameatx_np(parentFD, "Item.app", trashFD, "Item.app", UInt32(RENAME_EXCL))
        #expect(moved == 0)
        #expect(!FileManager.default.fileExists(atPath: item.path))

        chmod(trash.path, 0o700)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Item.app").path))
    }

    @Test("Still refuses a path that runs through a symlink")
    func refusesSymlinkComponent() throws {
        let sandbox = try Sandbox()
        let real = sandbox.root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = sandbox.root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(HelperDirectory.openWithoutFollowingSymlinks(link) == nil)
        #expect(HelperDirectory.openWithoutFollowingSymlinks(
            link.appendingPathComponent("Inside", isDirectory: true)
        ) == nil)
    }

    @Test("Refuses a path that climbs with .. instead of resolving it")
    func refusesDotDot() throws {
        let sandbox = try Sandbox()
        let inner = sandbox.root.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let climbing = URL(fileURLWithPath: inner.path + "/../Inner")
        #expect(HelperDirectory.openWithoutFollowingSymlinks(climbing) == nil)
        #expect(HelperDirectory.openWithoutFollowingSymlinks(URL(fileURLWithPath: inner.path + "/.")) == nil)
        // The same folder spelled plainly opens.
        let fd = HelperDirectory.openWithoutFollowingSymlinks(inner)
        #expect(fd != nil)
        if let fd { close(fd) }
    }

    @Test("Refuses a path whose last part is a file, not a folder")
    func refusesFile() throws {
        let sandbox = try Sandbox()
        let file = sandbox.root.appendingPathComponent("file.txt")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)))
        #expect(HelperDirectory.openWithoutFollowingSymlinks(file) == nil)
    }

    // MARK: Idle exit

    /// Collects scheduled timers so a test decides when each one fires.
    private final class ManualScheduler: @unchecked Sendable {
        var pending: [@Sendable () -> Void] = []
        var delays: [TimeInterval] = []

        var schedule: HelperIdleTracker.Scheduler {
            { [self] delay, work in
                delays.append(delay)
                pending.append(work)
            }
        }

        func fireAll() {
            let due = pending
            pending.removeAll()
            due.forEach { $0() }
        }
    }

    private final class ExitCounter: @unchecked Sendable {
        var count = 0
    }

    @Test("A helper nobody reaches quits after the idle interval")
    func quitsWhenNeverUsed() {
        let scheduler = ManualScheduler()
        let exits = ExitCounter()
        let tracker = HelperIdleTracker(idleInterval: 30, schedule: scheduler.schedule) { exits.count += 1 }
        tracker.start()
        #expect(scheduler.delays == [30])
        scheduler.fireAll()
        #expect(exits.count == 1)
    }

    @Test("Never quits while a connection or a move is open")
    func staysWhileHeld() {
        let scheduler = ManualScheduler()
        let exits = ExitCounter()
        let tracker = HelperIdleTracker(idleInterval: 30, schedule: scheduler.schedule) { exits.count += 1 }
        tracker.start()
        tracker.acquire() // connection
        tracker.acquire() // move in progress
        scheduler.fireAll()
        #expect(exits.count == 0)

        // The app gave up and closed the connection, but the move is still running.
        tracker.release()
        scheduler.fireAll()
        #expect(exits.count == 0)

        tracker.release()
        scheduler.fireAll()
        #expect(exits.count == 1)
    }

    @Test("A request inside the idle window cancels the pending quit")
    func newRequestCancelsPendingQuit() {
        let scheduler = ManualScheduler()
        let exits = ExitCounter()
        let tracker = HelperIdleTracker(idleInterval: 30, schedule: scheduler.schedule) { exits.count += 1 }
        tracker.acquire()
        tracker.release()        // arms a timer
        tracker.acquire()        // a new request arrives before it fires
        tracker.release()        // arms a second timer
        #expect(scheduler.pending.count == 2)
        scheduler.fireAll()
        // Only the newest timer may act, so the helper quits exactly once.
        #expect(exits.count == 1)
    }

    @Test("An extra release never goes below zero or quits early")
    func extraReleaseIsHarmless() {
        let scheduler = ManualScheduler()
        let exits = ExitCounter()
        let tracker = HelperIdleTracker(idleInterval: 30, schedule: scheduler.schedule) { exits.count += 1 }
        tracker.release()
        tracker.acquire()
        scheduler.fireAll()
        #expect(exits.count == 0)
    }
}
