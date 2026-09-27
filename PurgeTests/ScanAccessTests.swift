import Foundation
import Testing
@testable import Purge

@Suite("A limited scan stays out of folders macOS protects")
struct ScanAccessTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test
    func userFoldersAndOtherAppsDataAreProtected() {
        for relative in [
            "Desktop",
            "Documents/notes.txt",
            "Downloads/big.dmg",
            "Library/Containers/com.example.app/Data/Library/Caches",
            "Library/Group Containers/group.example",
            "Library/Mobile Documents/com~apple~CloudDocs",
            "Library/Safari"
        ] {
            #expect(ProtectedLocations.contains(home.appendingPathComponent(relative), home: home), "\(relative)")
        }
    }

    @Test
    func cachesAndDotFoldersAreNotProtected() {
        for relative in [
            "Library/Caches/com.example.app",
            "Library/Application Support/Google/Chrome/Default/Cache",
            "Library/Developer/Xcode/DerivedData",
            ".npm/_cacache",
            "Developer/project/node_modules"
        ] {
            #expect(!ProtectedLocations.contains(home.appendingPathComponent(relative), home: home), "\(relative)")
        }
    }

    /// A prefix match on the string alone would lock `~/DocumentsArchive` too.
    @Test
    func siblingWithSharedPrefixIsNotProtected() {
        #expect(!ProtectedLocations.contains(home.appendingPathComponent("DocumentsArchive"), home: home))
        #expect(!ProtectedLocations.contains(home.appendingPathComponent("Library/ContainersBackup"), home: home))
    }

    @Test
    func fullAccessReadsEverything() {
        let documents = home.appendingPathComponent("Documents/project")
        #expect(ProtectedLocations.isReadable(documents, access: .full, home: home))
        #expect(!ProtectedLocations.isReadable(documents, access: .limited, home: home))
    }

    /// `~/Developer` symlinked into Documents is a real setup. Following the link
    /// with `fileExists` would open Documents, so the check reads the link only.
    @Test
    func symlinkIntoProtectedFolderIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let target = fakeHome.appendingPathComponent("Documents/Developer", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let absoluteLink = fakeHome.appendingPathComponent("Developer")
        try fm.createSymbolicLink(at: absoluteLink, withDestinationURL: target)
        let relativeLink = fakeHome.appendingPathComponent("Code")
        try fm.createSymbolicLink(atPath: relativeLink.path, withDestinationPath: "Documents/Developer")
        let plain = fakeHome.appendingPathComponent("Projects", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)

        #expect(!ProtectedLocations.isReadable(absoluteLink, access: .limited, home: fakeHome))
        #expect(!ProtectedLocations.isReadable(relativeLink, access: .limited, home: fakeHome))
        #expect(ProtectedLocations.isReadable(plain, access: .limited, home: fakeHome))
    }

    @Test
    func gitDirectoryOfPlainRepositoryIsItsDotGit() throws {
        let repo = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)

        #expect(GitRepositoryFinder.gitDirectory(forRepository: repo) == dotGit.standardizedFileURL)
    }

    @Test
    func gitDirectoryOfWorktreeFollowsTheGitFile() throws {
        let repo = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dotGit = repo.appendingPathComponent(".git")

        try "gitdir: /Users/tester/Documents/app/.git/worktrees/feature\n"
            .write(to: dotGit, atomically: true, encoding: .utf8)
        #expect(
            GitRepositoryFinder.gitDirectory(forRepository: repo)?.path
                == "/Users/tester/Documents/app/.git/worktrees/feature"
        )

        try "gitdir: ../main/.git/worktrees/feature\n".write(to: dotGit, atomically: true, encoding: .utf8)
        #expect(
            GitRepositoryFinder.gitDirectory(forRepository: repo)?.path
                == repo.deletingLastPathComponent().appendingPathComponent("main/.git/worktrees/feature").standardizedFileURL.path
        )
    }

    /// The worktree in `~/Developer` whose git dir lives in `~/Documents` is the case
    /// this guards: `git status` there would make macOS ask about Documents.
    @Test
    func limitedScanDoesNotRunGitInAProtectedGitDir() async throws {
        let repo = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: repo) }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        try "gitdir: \(realHome)/Documents/purge-test-\(UUID().uuidString)/.git/worktrees/x\n"
            .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let item = repo.appendingPathComponent("Carthage-output", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)

        let checker = GitStatusChecker()
        await checker.setAccess(.limited)
        #expect(await checker.cleanupStatus(for: item) == .unknown)
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-scan-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // `/var` is a symlink to `/private/var`; resolve once so paths compare equal.
        return url.resolvingSymlinksInPath()
    }
}
