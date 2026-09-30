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

    /// Sizing these without Full Disk Access made macOS ask for "Media & Apple Music".
    @Test
    func appleMediaCachesAreProtected() {
        for relative in [
            "Library/Caches/com.apple.Music",
            "Library/Caches/com.apple.Music/SubscriptionPlayCache",
            "Library/Caches/com.apple.iTunes",
            "Library/Caches/com.apple.TV/Artwork"
        ] {
            #expect(ProtectedLocations.contains(home.appendingPathComponent(relative), home: home), "\(relative)")
            #expect(!ProtectedLocations.isReadable(home.appendingPathComponent(relative), access: .limited, home: home), "\(relative)")
        }
        // A sibling that only shares the prefix is still scanned.
        #expect(!ProtectedLocations.contains(home.appendingPathComponent("Library/Caches/com.apple.MusicKit"), home: home))
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

    /// APFS and TCC both ignore case, so `~/documents` is Documents.
    @Test
    func protectedRootsMatchInAnyCase() {
        #expect(ProtectedLocations.contains(home.appendingPathComponent("documents/code"), home: home))
        #expect(ProtectedLocations.contains(home.appendingPathComponent("DESKTOP"), home: home))
        #expect(ProtectedLocations.contains(home.appendingPathComponent("library/containers/com.example"), home: home))
        #expect(!ProtectedLocations.contains(home.appendingPathComponent("documentsArchive"), home: home))
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

    /// A link one level down, inside a folder the walk is allowed into. Checking
    /// only the final path would read `client` as fine and walk into Documents.
    @Test
    func nestedSymlinkUnderProjectsIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Documents/client"), withIntermediateDirectories: true)
        let projects = fakeHome.appendingPathComponent("Projects", isDirectory: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        let client = projects.appendingPathComponent("client")
        try fm.createSymbolicLink(atPath: client.path, withDestinationPath: "../Documents/client")
        let recorder = RecordingFileManager()

        #expect(!ProtectedLocations.isReadable(client, access: .limited, home: fakeHome, fileManager: recorder))
        #expect(ProtectedLocations.isReadable(projects, access: .limited, home: fakeHome))
        #expect(ProtectedLocations.isReadable(client, access: .full, home: fakeHome))
        // The link was read; nothing inside Documents was. The recorded paths are
        // resolved, so `/var` shows up as `/private/var`.
        #expect(recorder.readLinks.contains { $0.hasSuffix("/Projects/client") })
        #expect(!recorder.readLinks.contains { $0.hasSuffix("/Documents") || $0.contains("/Documents/") })
    }

    /// A link spelled `documents` resolves to Documents on the default volume.
    /// An exact-case check would clear it and open the folder.
    @Test
    func symlinkIntoProtectedFolderInOtherCaseIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Documents/code"), withIntermediateDirectories: true)
        let projects = fakeHome.appendingPathComponent("Projects")
        try fm.createSymbolicLink(atPath: projects.path, withDestinationPath: "documents/code")
        let recorder = RecordingFileManager()

        #expect(!ProtectedLocations.isReadable(projects, access: .limited, home: fakeHome, fileManager: recorder))
        #expect(!recorder.readLinks.contains { $0.lowercased().contains("/documents") })
    }

    /// `..` after a link steps out of the link's target, as the kernel resolves
    /// it. Folded as text, `Projects/client/../x` would read as `Projects/x`.
    @Test
    func parentStepAfterALinkLeavesTheLinksTarget() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Documents/client"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Projects/other"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: fakeHome.appendingPathComponent("Projects/client").path,
            withDestinationPath: "../Documents/client"
        )

        let throughLink = URL(fileURLWithPath: fakeHome.path + "/Projects/client/../x", isDirectory: true)
        let throughFolder = URL(fileURLWithPath: fakeHome.path + "/Projects/other/../x", isDirectory: true)
        #expect(!ProtectedLocations.isReadable(throughLink, access: .limited, home: fakeHome))
        #expect(ProtectedLocations.isReadable(throughFolder, access: .limited, home: fakeHome))
    }

    /// The project walk decides on these prefetched values before it recurses.
    /// Neither may describe a link's target, or listing `~/Projects` would stat
    /// `~/Projects/client` through a link into Documents.
    @Test
    func directoryListingDescribesLinksNotTheirTargets() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let projects = fakeHome.appendingPathComponent("Projects", isDirectory: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Elsewhere/client"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: projects.appendingPathComponent("client").path, withDestinationPath: "../Elsewhere/client")

        let entries = try fm.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey],
            options: [.skipsPackageDescendants]
        )
        let values = try #require(entries.first).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(values.isDirectory == false)
    }

    /// Safe and scheduled cleanups check each candidate. A `node_modules` whose
    /// project folder is the link must wait for access like anything in Documents.
    @Test
    func cleanupCandidateUnderALinkedParentIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let target = fakeHome.appendingPathComponent("Documents/client", isDirectory: true)
        try fm.createDirectory(at: target.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: fakeHome.appendingPathComponent("Projects/client"), withDestinationURL: target)

        let candidate = fakeHome.appendingPathComponent("Projects/client/node_modules", isDirectory: true)
        #expect(!ProtectedLocations.isReadable(candidate, access: .limited, home: fakeHome))

        let plain = fakeHome.appendingPathComponent("Projects/other/node_modules", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(ProtectedLocations.isReadable(plain, access: .limited, home: fakeHome))
    }

    /// Caches and Application Support are in a limited scan, but a folder there
    /// can still point into Documents.
    @Test
    func cacheFolderSymlinkedIntoDocumentsIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let target = fakeHome.appendingPathComponent("Documents/big-cache", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let caches = fakeHome.appendingPathComponent("Library/Caches", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let linkedCache = caches.appendingPathComponent("com.example.app")
        try fm.createSymbolicLink(at: linkedCache, withDestinationURL: target)
        let appSupport = fakeHome.appendingPathComponent("Library/Application Support/Example", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: appSupport.appendingPathComponent("Cache"), withDestinationURL: target)
        let realCache = caches.appendingPathComponent("com.example.other", isDirectory: true)
        try fm.createDirectory(at: realCache, withIntermediateDirectories: true)

        #expect(!ProtectedLocations.isReadable(linkedCache, access: .limited, home: fakeHome))
        #expect(!ProtectedLocations.isReadable(appSupport.appendingPathComponent("Cache"), access: .limited, home: fakeHome))
        #expect(ProtectedLocations.isReadable(realCache, access: .limited, home: fakeHome))
    }

    /// A link that lands somewhere readable resolves to where it lands, which is
    /// what the project walk judges the rest of the tree by.
    @Test
    func readablePathFollowsLinksToTheirRealLocation() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let real = fakeHome.appendingPathComponent("Volumes/Code", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = fakeHome.appendingPathComponent("Developer")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(ProtectedLocations.readablePath(of: link, home: fakeHome) == physicalPath(real))
        #expect(
            ProtectedLocations.readablePath(of: link.appendingPathComponent("app"), home: fakeHome)
                == physicalPath(real) + "/app"
        )

        // A link back to home makes `~/Code/Documents` the real Documents.
        let homeLink = fakeHome.appendingPathComponent("Code")
        try fm.createSymbolicLink(atPath: homeLink.path, withDestinationPath: ".")
        #expect(ProtectedLocations.readablePath(of: homeLink, home: fakeHome) == physicalPath(fakeHome))
        #expect(!ProtectedLocations.isReadable(homeLink.appendingPathComponent("Documents"), access: .limited, home: fakeHome))
    }

    @Test
    func longSymlinkChainIsNotReadable() throws {
        // Physical, so `/var` does not add a hop to every link in the chain.
        let fakeHome = URL(fileURLWithPath: physicalPath(try makeTemporaryHome()), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        let end = fakeHome.appendingPathComponent("end", isDirectory: true)
        try fm.createDirectory(at: end, withIntermediateDirectories: true)

        // prefix0 -> prefix1 -> … -> end, one hop per link.
        func makeChain(length: Int, prefix: String) throws -> URL {
            var next = end
            for index in stride(from: length - 1, through: 0, by: -1) {
                let link = fakeHome.appendingPathComponent("\(prefix)\(index)")
                try fm.createSymbolicLink(at: link, withDestinationURL: next)
                next = link
            }
            return next
        }
        let short = try makeChain(length: ProtectedLocations.maxSymlinkHops, prefix: "short")
        let long = try makeChain(length: ProtectedLocations.maxSymlinkHops + 1, prefix: "long")

        #expect(ProtectedLocations.isReadable(short, access: .limited, home: fakeHome))
        #expect(!ProtectedLocations.isReadable(long, access: .limited, home: fakeHome))

        let loop = fakeHome.appendingPathComponent("loop")
        try fm.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        #expect(!ProtectedLocations.isReadable(loop, access: .limited, home: fakeHome))
    }

    @Test
    func gitDirectoryOfPlainRepositoryIsItsDotGit() throws {
        let repo = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)

        #expect(GitRepositoryFinder.gitDirectory(forRepository: repo)?.path == dotGit.path)
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

        // Joined as text, `..` included: resolving it is `isReadable`'s job.
        try "gitdir: ../main/.git/worktrees/feature\n".write(to: dotGit, atomically: true, encoding: .utf8)
        #expect(
            GitRepositoryFinder.gitDirectory(forRepository: repo)?.path
                == repo.path + "/../main/.git/worktrees/feature"
        )
    }

    /// A relative `gitdir:` can climb out through a link. Standardizing it would
    /// stat inside Documents; kept as text, `isReadable` sees where it lands.
    @Test
    func worktreeGitDirThroughALinkIntoDocumentsIsNotReadable() throws {
        let fakeHome = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fm = FileManager.default
        try fm.createDirectory(at: fakeHome.appendingPathComponent("Documents/app"), withIntermediateDirectories: true)
        let repo = fakeHome.appendingPathComponent("Developer/feature", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: repo.appendingPathComponent("app").path, withDestinationPath: "../../Documents/app")
        try "gitdir: app/../x/.git\n".write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let gitDir = try #require(GitRepositoryFinder.gitDirectory(forRepository: repo))
        #expect(gitDir.path == repo.path + "/app/../x/.git")
        #expect(!ProtectedLocations.isReadable(gitDir, access: .limited, home: fakeHome))
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

    /// `.git` itself linked into Documents. Following it to look for a `gitdir:`
    /// line, or even to see that it exists, would open Documents.
    @Test
    func limitedScanDoesNotFollowADotGitLink() async throws {
        let repo = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: repo) }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent(".git").path,
            withDestinationPath: "\(realHome)/Documents/purge-test-\(UUID().uuidString)/.git"
        )
        let item = repo.appendingPathComponent("Carthage-output", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)

        let checker = GitStatusChecker()
        await checker.setAccess(.limited)
        #expect(await checker.cleanupStatus(for: item) == .unknown)
    }

    /// Records every link `isReadable` reads, to prove it never reads inside a root.
    private final class RecordingFileManager: FileManager {
        private(set) var readLinks: [String] = []

        override func destinationOfSymbolicLink(atPath path: String) throws -> String {
            readLinks.append(path)
            return try super.destinationOfSymbolicLink(atPath: path)
        }
    }

    /// The path with every link resolved, `/private` included, which is the form
    /// `readablePath` returns. `resolvingSymlinksInPath` strips `/private` again.
    private func physicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-scan-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // `/var` is a symlink to `/private/var`; resolve once so paths compare equal.
        return url.resolvingSymlinksInPath()
    }
}
