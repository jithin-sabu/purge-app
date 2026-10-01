import Foundation
import Testing
@testable import Purge

/// Rooted under the real home directory: the git lookup stops at home, and
/// `collectArtifacts` refuses anything outside it. Removed again in `cleanUp`.
private struct ActivityFixture {
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".purge-test-fixtures", isDirectory: true)

    let root: URL

    init(files: [String] = [], folders: [String] = []) throws {
        root = Self.container.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: url(folder), withIntermediateDirectories: true)
        }
        for file in files {
            try write("", to: file)
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func write(_ text: String, to relative: String) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
    }

    func setDate(_ date: Date, of relative: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relative).path)
    }

    /// Every entry, deepest first so a parent's date is set after its children
    /// stop touching it. Links are skipped: setting their date would date the target.
    func ageEverything(to date: Date) throws {
        let fm = FileManager.default
        var paths: [String] = []
        if let enumerator = fm.enumerator(atPath: root.path) {
            for case let relative as String in enumerator { paths.append(relative) }
        }
        for relative in paths.sorted(by: { $0.count > $1.count }) {
            let attributes = try fm.attributesOfItem(atPath: url(relative).path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            try setDate(date, of: relative)
        }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        // Shared with other suites running in parallel, so only removed when empty.
        let remaining = (try? FileManager.default.contentsOfDirectory(at: Self.container, includingPropertiesForKeys: nil)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: Self.container) }
    }
}

private let now = Date()
private let longAgo = now.addingTimeInterval(-400 * 86_400)
private let cutoff = now.addingTimeInterval(-180 * 86_400)

@Suite("A project's age comes from the project, not its artifact folder")
struct ProjectActivityTests {
    private func isActive(_ fixture: ActivityFixture, project: String = "", entryLimit: Int = ProjectActivityPolicy.walkEntryLimit) -> Bool {
        let root = project.isEmpty ? fixture.root : fixture.url(project)
        return ProjectActivityPolicy.hasActivity(
            since: cutoff,
            projectRoot: root,
            artifactPaths: [root.appendingPathComponent("node_modules")],
            access: .full,
            entryLimit: entryLimit
        )
    }

    @Test("an old node_modules in a project edited today is active")
    func recentSourceEditBeatsOldArtifact() throws {
        let fixture = try ActivityFixture(files: ["package.json", "src/deep/app.js"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "src/deep/app.js")
        #expect(isActive(fixture))
    }

    @Test("a project with nothing newer than the cutoff is not active")
    func everythingOld() throws {
        let fixture = try ActivityFixture(files: ["package.json", "src/app.js"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        #expect(!isActive(fixture))
    }

    @Test("changes inside an artifact folder are not walked")
    func artifactContentsAreSkipped() throws {
        let fixture = try ActivityFixture(files: ["package.json", "node_modules/pkg/index.js"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "node_modules/pkg/index.js")
        #expect(!isActive(fixture))
    }

    @Test("a recent artifact folder date still counts, as it did before")
    func artifactFolderDateStillCounts() throws {
        let fixture = try ActivityFixture(files: ["package.json"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "node_modules")
        #expect(isActive(fixture))
    }

    @Test("a recent git index is activity even when no file changed")
    func recentGitIndex() throws {
        let fixture = try ActivityFixture(files: ["package.json", ".git/index", ".git/HEAD"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: ".git/index")
        #expect(isActive(fixture))
    }

    @Test("a linked worktree's git dir is read through its .git file")
    func linkedWorktreeGitDir() throws {
        let fixture = try ActivityFixture(
            files: ["project/package.json", "main/.git/worktrees/project/index"],
            folders: ["project/node_modules"]
        )
        defer { fixture.cleanUp() }
        try fixture.write("gitdir: \(fixture.url("main/.git/worktrees/project").path)\n", to: "project/.git")
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "main/.git/worktrees/project/index")
        #expect(isActive(fixture, project: "project"))
    }

    @Test("a link to a recent folder outside the project is not followed")
    func linksAreNotFollowed() throws {
        let fixture = try ActivityFixture(files: ["project/package.json", "elsewhere/new.txt"], folders: ["project/node_modules"])
        defer { fixture.cleanUp() }
        try FileManager.default.createSymbolicLink(
            at: fixture.url("project/linked"), withDestinationURL: fixture.url("elsewhere")
        )
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "elsewhere/new.txt")
        try fixture.setDate(now, of: "elsewhere")
        #expect(!isActive(fixture, project: "project"))
    }

    @Test("hitting the entry limit falls back to not active, the old behaviour")
    func entryLimitFallsBack() throws {
        let fixture = try ActivityFixture(files: ["package.json", "src/app.js"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "src/app.js")
        #expect(!isActive(fixture, entryLimit: 0))
    }

    @Test("a repo at home is ignored, so a dotfiles repo cannot make every project look busy")
    func gitLookupStopsBelowHome() throws {
        let fixture = try ActivityFixture(files: [".git/index"], folders: ["project"])
        defer { fixture.cleanUp() }
        // The fixture root stands in for home.
        #expect(ProjectActivityPolicy.gitDirectory(
            forProject: fixture.url("project"), access: .full, home: fixture.root
        ) == nil)
        #expect(ProjectActivityPolicy.gitDirectory(
            forProject: fixture.url("project"), access: .full, home: fixture.root.deletingLastPathComponent()
        ) != nil)
    }
}

@Suite("A project someone is using right now is never listed")
struct ProjectInUseTests {
    private func inUse(_ root: URL, cwds: [String]) -> Bool {
        ProjectActivityPolicy.isInUse(
            projectRoot: root,
            live: .init(workingDirectories: Set(cwds)),
            access: .full
        )
    }

    @Test("a process working in the project or below it")
    func processInside() throws {
        let fixture = try ActivityFixture(folders: ["project/src"])
        defer { fixture.cleanUp() }
        let project = fixture.url("project")
        #expect(inUse(project, cwds: [project.path]))
        #expect(inUse(project, cwds: [fixture.url("project/src").path]))
        #expect(!inUse(project, cwds: []))
        #expect(!inUse(project, cwds: [fixture.root.path]))
    }

    @Test("a sibling whose name starts with the project's name does not count")
    func siblingPrefixIsNotInside() throws {
        let fixture = try ActivityFixture(folders: ["project", "project-2"])
        defer { fixture.cleanUp() }
        #expect(!inUse(fixture.url("project"), cwds: [fixture.url("project-2").path]))
    }

    @Test("a project reached through a link matches a process in its real folder")
    func resolvedSpelling() throws {
        let fixture = try ActivityFixture(folders: ["real"])
        defer { fixture.cleanUp() }
        try FileManager.default.createSymbolicLink(at: fixture.url("link"), withDestinationURL: fixture.url("real"))
        let realPath = fixture.url("real").resolvingSymlinksInPath().path
        #expect(inUse(fixture.url("link"), cwds: [realPath]))
    }

    @Test("a git lock means a git command is running in the project")
    func gitLock() throws {
        let fixture = try ActivityFixture(files: ["project/.git/HEAD"])
        defer { fixture.cleanUp() }
        let project = fixture.url("project")
        #expect(!inUse(project, cwds: []))
        try fixture.write("", to: "project/.git/index.lock")
        #expect(inUse(project, cwds: []))
    }
}

@Suite("Developer Projects lists only unused projects, end to end")
struct ProjectListingFilterTests {
    private func listed(
        _ fixture: ActivityFixture,
        staleDays: Int = DevToolsStalenessOption.sixMonths.rawValue,
        cwds: [String] = []
    ) -> Set<DeletableArtifactKind>? {
        let filter = DevScanner.ProjectListingFilter(
            staleDays: staleDays,
            now: now,
            live: .init(workingDirectories: Set(cwds))
        )
        let (group, _) = DevScanner.sizeProjectGroup(
            rootURL: fixture.root, types: [.node], access: .full, filter: filter
        )
        return group.map { Set($0.artifacts.map(\.kind)) }
    }

    private func nodeProject() throws -> ActivityFixture {
        let fixture = try ActivityFixture(
            files: ["package.json", "package-lock.json", "src/app.js", "node_modules/pkg/index.js"]
        )
        try fixture.ageEverything(to: longAgo)
        return fixture
    }

    @Test("an unused project is listed")
    func unusedProjectListed() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        #expect(listed(fixture) == [.nodeModules])
    }

    @Test("a project edited recently is not listed, however old node_modules is")
    func recentlyEditedProjectHidden() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        try fixture.setDate(now, of: "src/app.js")
        #expect(listed(fixture) == nil)
    }

    @Test("an old project with a process working in it is not listed")
    func inUseProjectHidden() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        #expect(listed(fixture, cwds: [fixture.root.path]) == nil)
    }

    @Test("Show all lists recent projects but still hides ones in use")
    func showAll() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        try fixture.setDate(now, of: "src/app.js")
        let showAll = DevToolsStalenessOption.showAll.rawValue
        #expect(listed(fixture, staleDays: showAll) == [.nodeModules])
        #expect(listed(fixture, staleDays: showAll, cwds: [fixture.root.path]) == nil)
    }
}
