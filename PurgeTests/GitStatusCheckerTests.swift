import Foundation
import Testing
@testable import Purge

/// The git check decides whether a project's folders can be Safe to Clean, and
/// Clean Safe Items asks it again right before it moves anything. These run it
/// the way a scan does, on real repositories in the temporary folder.
@Suite("Git status checker")
struct GitStatusCheckerTests {
    /// A PHP project's `vendor` is not on the rebuildable list, so the check runs
    /// `git status` for it. If it read clean, or `vendor` joined the list, Clean
    /// Safe Items and scheduled cleans would take it beside uncommitted work.
    @Test
    func folderBesideUncommittedChangesReadsDirty() async throws {
        let project = try TemporaryRepository()
        defer { project.remove() }
        try project.write("{}", to: "composer.json")
        try project.git("add", "composer.json")
        try project.git("-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init")
        let vendor = project.folder.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)

        #expect(await GitStatusChecker().cleanupStatus(for: vendor) == .clean)

        try project.write("{\"name\": \"edited\"}", to: "composer.json")
        #expect(await GitStatusChecker().cleanupStatus(for: vendor) == .dirty)
    }

    /// A new scan clears the cache so `git` runs again. A `git status` that started
    /// before the clear used to write its answer into the new cache anyway, and
    /// the next scan and the clean-time check then trusted it (#172).
    @Test
    func answerReadBeforeAClearIsNotKept() async throws {
        let project = try TemporaryRepository(gitFolderOnly: true)
        defer { project.remove() }
        let vendor = project.folder.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let git = HeldGit()
        let checker = GitStatusChecker(readStatus: { _ in await git.read() })

        let first = Task { await checker.cleanupStatus(for: vendor) }
        #expect(await eventually { await git.isHolding })
        await checker.clearSessionCache()
        await git.release()

        #expect(await first.value == .unknown)
        #expect(await checker.cleanupStatus(for: vendor) == .dirty)
        #expect(await git.reads == 2)
    }

    // MARK: Helpers

    /// A repository in its own temporary folder.
    private struct TemporaryRepository {
        let folder: URL

        /// `gitFolderOnly` makes an empty `.git` folder, which is enough for the
        /// checker to find the repository when a test supplies the answers.
        init(gitFolderOnly: Bool = false) throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PurgeGitStatusCheckerTests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("project", isDirectory: true)
            if gitFolderOnly {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try git("init", "-q")
            }
        }

        func write(_ text: String, to relative: String) throws {
            try Data(text.utf8).write(to: folder.appendingPathComponent(relative))
        }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
    }

    /// Answers clean the first time, after the test lets it go, and dirty after that.
    /// A release that comes before the first read lets it through, so a test that
    /// gave up waiting fails instead of hanging.
    private actor HeldGit {
        private(set) var reads = 0
        private(set) var isHolding = false
        private var released = false
        private var held: CheckedContinuation<Void, Never>?

        func read() async -> GitWorktreeStatus {
            reads += 1
            guard reads == 1 else { return .dirty }
            guard !released else { return .clean }
            await withCheckedContinuation { continuation in
                held = continuation
                isHolding = true
            }
            return .clean
        }

        func release() {
            released = true
            held?.resume()
            held = nil
            isHolding = false
        }
    }

    private func eventually(
        timeout: TimeInterval = 30,
        _ condition: () async -> Bool
    ) async -> Bool {
        // Counts only the time this loop was running: on CI the test host can
        // stall for tens of seconds with every suite waiting, and a wall-clock
        // deadline expires during the stall through no fault of the condition.
        var waited: TimeInterval = 0
        var last = Date()
        while !(await condition()) {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}
