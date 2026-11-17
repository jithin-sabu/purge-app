import Foundation
import Testing
@testable import Purge

/// Projects in a folder the user added for Developer Projects (#318). The
/// list the gate reads is bound with `ScanFolders.$snapshotOverride`, so no
/// test saves one or reads the user's.
@Suite("Developer Projects in folders the user adds (#318)")
struct ProjectAddedFolderTests {
    /// A folder outside any home, standing in for a drive.
    private struct Drive {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-added-projects-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
            return url
        }

        func url(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: true) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A home that holds none of the fixtures.
    private let otherHome = "/Users/purge-test-nobody"

    @Test("A catalog artifact under an added folder passes, and only while the folder is added")
    func artifactUnderAddedFolder() throws {
        let drive = try Drive()
        defer { drive.remove() }
        let code = drive.url("Code")
        try drive.write("Code/app/package.json")
        try drive.write("Code/app/node_modules/pkg/index.js")
        try drive.write("Elsewhere/app/package.json")
        try drive.write("Elsewhere/app/node_modules/pkg/index.js")
        let artifact = drive.url("Code/app/node_modules")

        #expect(DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            artifact, home: otherHome, addedRoots: [code.standardizedFileURL.path]
        ))
        #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            artifact, home: otherHome, addedRoots: []
        ))
        // A project beside the added folder is not in it.
        #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            drive.url("Elsewhere/app/node_modules"), home: otherHome, addedRoots: [code.standardizedFileURL.path]
        ))
        // The snapshot is what the gate reads when no list is passed.
        let snapshot = ScanFolders.Snapshot(walked: [code.standardizedFileURL.path], saved: [code.standardizedFileURL.path])
        ScanFolders.$snapshotOverride.withValue(snapshot) {
            #expect(DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(artifact, home: otherHome))
        }
    }

    @Test("A folder with only a project's name and no marker is not taken from an added folder")
    func nameAloneIsNotEnough() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("Code/notes/node_modules/readme.txt")
        try drive.write("Code/notes/build/output.txt")

        for folder in ["Code/notes/node_modules", "Code/notes/build"] {
            #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                drive.url(folder), home: otherHome, addedRoots: [drive.url("Code").standardizedFileURL.path]
            ))
        }
    }

    @Test("On an added drive, a project inside a Library folder is refused, while Unity's own Library passes")
    func libraryOnADrive() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("Library/Tools/app/package.json")
        try drive.write("Library/Tools/app/node_modules/pkg/index.js")
        try drive.write("Games/Racer/ProjectSettings/ProjectVersion.txt")
        try drive.write("Games/Racer/Library/ArtifactDB")
        let added = [drive.root.standardizedFileURL.path]

        #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            drive.url("Library/Tools/app/node_modules"), home: otherHome, addedRoots: added
        ))
        #expect(DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            drive.url("Games/Racer/Library"), home: otherHome, addedRoots: added
        ))
    }

    @Test("The git lookup for a project on a drive climbs to the added folder")
    func gitLookupStopsAtAddedFolder() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("Repo/.git/HEAD")
        try drive.write("Repo/packages/app/package.json")
        let project = drive.url("Repo/packages/app")
        let home = FileManager.default.homeDirectoryForCurrentUser

        #expect(ProjectActivityPolicy.gitDirectory(forProject: project, access: .full, home: home) == nil)
        let added = drive.url("Repo").standardizedFileURL.path
        ScanFolders.$snapshotOverride.withValue(.init(walked: [added], saved: [added])) {
            let gitDir = ProjectActivityPolicy.gitDirectory(forProject: project, access: .full, home: home)
            #expect(gitDir?.standardizedFileURL.path == drive.url("Repo/.git").standardizedFileURL.path)
        }
    }

    @Test("A project in a folder added inside home keeps the home rules")
    func homeAddedFolderKeepsHomeRules() throws {
        let fixture = try ActivityFixture(
            files: ["package.json", "package-lock.json", "src/app.js", "node_modules/pkg/index.js"]
        )
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: Date(timeIntervalSinceNow: -3 * 365 * 86_400))
        let filter = DevScanner.ProjectListingFilter(
            staleDays: DevToolsStalenessOption.sixMonths.rawValue,
            now: Date(),
            live: .none
        )
        let added = fixture.root.standardizedFileURL.path

        let artifacts = ScanFolders.$snapshotOverride.withValue(.init(walked: [added], saved: [added])) {
            DevScanner.sizeProjectGroup(rootURL: fixture.root, types: [.node], access: .full, filter: filter).0?.artifacts
        }
        let listed = try #require(artifacts)
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { $0.safetyInfo.level == .safe && $0.checkFirstReason == nil })
    }

    @Test("On an added folder, a project inside an app bundle is refused and never walked into")
    func appBundleOnADrive() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("Applications/Code.app/Contents/Resources/app/package.json")
        try drive.write("Applications/Code.app/Contents/Resources/app/node_modules/pkg/index.js")
        let added = [drive.root.standardizedFileURL.path]

        #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
            drive.url("Applications/Code.app/Contents/Resources/app/node_modules"), home: otherHome, addedRoots: added
        ))
        let found = DevScanner.findProjectRoots(
            in: [drive.root], home: URL(fileURLWithPath: otherHome), access: .full, maxDepth: 6
        ).roots.map(\.0.path)
        #expect(!found.contains { $0.contains("Code.app") })
    }

    @Test("On an added drive, a project in a copied Mac, home folder or synced folder is refused and not found")
    func copiesOnADrive() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("OldMac/System/.keep")
        try drive.write("OldMac/Users/bob/site/package.json")
        try drive.write("OldMac/Users/bob/site/node_modules/pkg/index.js")
        try drive.write("Dropbox/.dropbox")
        try drive.write("Dropbox/app/package.json")
        try drive.write("Dropbox/app/node_modules/pkg/index.js")
        try drive.write("Code/app/package.json")
        try drive.write("Code/app/node_modules/pkg/index.js")
        let added = [drive.root.standardizedFileURL.path]

        for blocked in ["OldMac/Users/bob/site/node_modules", "Dropbox/app/node_modules"] {
            #expect(!DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(drive.url(blocked), home: otherHome, addedRoots: added))
        }
        #expect(DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(drive.url("Code/app/node_modules"), home: otherHome, addedRoots: added))

        let snapshot = ScanFolders.Snapshot(walked: added, saved: added)
        let found = ScanFolders.$snapshotOverride.withValue(snapshot) {
            DevScanner.findProjectRoots(
                in: [drive.root], home: URL(fileURLWithPath: otherHome), access: .full, maxDepth: 6
            ).roots.map { $0.0.lastPathComponent }
        }
        #expect(found.contains("app"))
        #expect(!found.contains("site"))
        #expect(found.filter { $0 == "app" }.count == 1)
    }
}

extension ProjectAddedFolderTests {
    @Test("Below an added folder, the project walk never lists a mount that isn't a local disk")
    func nonLocalMountIsNotWalked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-added-mounts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["Share/app/package.json", "Share/app/node_modules/pkg/index.js",
                     "Code/app/package.json", "Code/app/node_modules/pkg/index.js"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let added = root.standardizedFileURL.path
        // The listing spells the temporary folder `/private/var/…`.
        let share = root.appendingPathComponent("Share").resolvingSymlinksInPath().path
        let found = ScanFolders.$snapshotOverride.withValue(.init(walked: [added], saved: [added])) {
            DevScanner.findProjectRoots(
                in: [root], home: URL(fileURLWithPath: "/Users/purge-test-nobody"), access: .full,
                maxDepth: 6, nonLocalMounts: [share, String(share.dropFirst("/private".count))]
            ).roots.map { $0.0.path }
        }
        #expect(found.contains { $0.hasSuffix("/Code/app") })
        #expect(!found.contains { $0.contains("/Share/") })
    }
}

extension ProjectAddedFolderTests {
    @Test("A linked project root is never listed, so nothing on a drive is reached through it")
    func linkedRootIsNotListed() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-linked-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for file in ["Drive/Code/site/package.json", "Drive/Code/site/node_modules/pkg/index.js"] {
            let url = base.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let home = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let projects = home.appendingPathComponent("Projects")
        try fm.createSymbolicLink(at: projects, withDestinationURL: base.appendingPathComponent("Drive/Code"))

        let found = DevScanner.findProjectRoots(in: [projects], home: home, access: .full, maxDepth: 6).roots
        #expect(found.isEmpty)
    }
}

@MainActor
@Suite("Clean Safe Items never takes anything from an added folder (#318)")
struct AddedFolderSafeCleanTests {
    private func artifact(
        under root: URL,
        reason: ProjectCheckFirstReason?
    ) -> ProjectCacheArtifact {
        let path = root.appendingPathComponent("app/node_modules", isDirectory: true)
        return ProjectCacheArtifact(
            kind: .nodeModules,
            path: path,
            projectRoot: root.appendingPathComponent("app", isDirectory: true),
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            // Safe, as a row the user overrode to Safe would be.
            safetyInfo: SafetyInfo(level: .safe, headline: "node_modules", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallSafety: .notApplicable,
            gitStatus: .clean,
            checkFirstReason: reason
        )
    }

    private func store(with artifact: ProjectCacheArtifact, _ scans: FakeScans) -> PurgeStore {
        scans.hasAccess = true
        let store = scans.makeStore()
        store.projectGroups = [ProjectGroup(
            displayName: "app",
            rootPath: artifact.projectRoot,
            inferredTypes: [.node],
            artifacts: [artifact]
        )]
        return store
    }

    /// A path that does not exist, so nothing on disk decides the answer.
    private let drive = URL(fileURLWithPath: "/Volumes/purge-test-\(UUID().uuidString)/Code", isDirectory: true)

    @Test("An added-folder row overridden to Safe stays out")
    func overriddenRowStaysOut() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = store(with: artifact(under: drive, reason: .addedFolder), scans)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test("A path in a saved folder stays out, even with its drive unplugged")
    func savedFolderPathStaysOut() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = store(with: artifact(under: drive, reason: nil), scans)
        // Control: without the saved folder the same Safe row is a candidate.
        #expect(store.manualSafeCleanupCandidates().count == 1)
        ScanFolders.$snapshotOverride.withValue(.init(walked: [], saved: [drive.path])) {
            #expect(store.manualSafeCleanupCandidates().isEmpty)
        }
    }

    @Test("A folder added inside home doesn't keep its projects out")
    func homeSavedFolderDoesNotFilter() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("purge-test-\(UUID().uuidString)/Code", isDirectory: true)
        let store = store(with: artifact(under: home, reason: nil), scans)
        ScanFolders.$snapshotOverride.withValue(.init(walked: [home.path], saved: [home.path])) {
            #expect(store.manualSafeCleanupCandidates().count == 1)
        }
    }

    @Test("The safe totals leave out what Clean Safe Items leaves out")
    func safeTotalsMatchTheClean() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = store(with: artifact(under: drive, reason: nil), scans)
        ScanFolders.$snapshotOverride.withValue(.init(walked: [], saved: [drive.path])) {
            #expect(store.safeCleanupSummary.projectArtifactBytes == 0)
            #expect(store.manualSafeCleanupCandidates().isEmpty)
        }
    }
}
