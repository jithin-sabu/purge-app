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
        try Self.makeRoot(root)
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

    /// Another suite's `cleanUp` can remove the empty container between the
    /// container being made and `root` being made inside it, so that is tried again.
    private static func makeRoot(_ root: URL) throws {
        for attempt in 1...5 {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return
            } catch where attempt < 5 {
                continue
            }
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        // Shared with other suites running in parallel, so only removed when empty.
        // rmdir checks and removes in one step. Listing it first and then removing
        // it whole took a fixture another suite made between the two, and failed
        // that suite's test on CI.
        rmdir(Self.container.path)
    }
}

private let now = Date()
private let longAgo = now.addingTimeInterval(-400 * 86_400)
private let cutoff = now.addingTimeInterval(-180 * 86_400)

@Suite("A project's age comes from the project, not its artifact folder")
struct ProjectActivityTests {
    private func activity(
        _ fixture: ActivityFixture, project: String = "", entryLimit: Int = ProjectActivityPolicy.walkEntryLimit
    ) -> ProjectActivityPolicy.Activity {
        let root = project.isEmpty ? fixture.root : fixture.url(project)
        return ProjectActivityPolicy.activity(
            since: cutoff,
            projectRoot: root,
            artifactPaths: [root.appendingPathComponent("node_modules")],
            access: .full,
            entryLimit: entryLimit
        )
    }

    private func isActive(_ fixture: ActivityFixture, project: String = "") -> Bool {
        activity(fixture, project: project) == .recent
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

    @Test("an edit in a folder that only shares an artifact's name counts")
    func sameNameFolderIsWalked() throws {
        let fixture = try ActivityFixture(files: ["package.json", "build/release.sh"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "build/release.sh")
        #expect(isActive(fixture))
    }

    @Test("a folder that is offered is still skipped, whatever its name")
    func offeredFolderIsSkipped() throws {
        let fixture = try ActivityFixture(files: ["build.gradle", "build/out/app.jar"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "build/out/app.jar")
        #expect(ProjectActivityPolicy.activity(
            since: cutoff,
            projectRoot: fixture.root,
            artifactPaths: [fixture.url("build")],
            access: .full
        ) == .none)
    }

    @Test("a dependency tree nested anywhere in the project is skipped")
    func nestedDependencyTreeIsSkipped() throws {
        let fixture = try ActivityFixture(files: ["package.json", "tools/.venv/lib/site.py", "ios/Pods/Pod/a.m"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "tools/.venv/lib/site.py")
        try fixture.setDate(now, of: "ios/Pods/Pod/a.m")
        #expect(activity(fixture) == .none)
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

    @Test("a walk that hits the entry limit is too big to check, not unused")
    func entryLimitIsTooBigToCheck() throws {
        let fixture = try ActivityFixture(files: ["package.json", "src/app.js"], folders: ["node_modules"])
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        #expect(activity(fixture) == .none)
        #expect(activity(fixture, entryLimit: 0) == .tooBigToCheck)
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

    private func showAllArtifacts(_ fixture: ActivityFixture) -> [ProjectCacheArtifact] {
        let filter = DevScanner.ProjectListingFilter(
            staleDays: DevToolsStalenessOption.showAll.rawValue,
            now: now,
            live: .none
        )
        let (group, _) = DevScanner.sizeProjectGroup(
            rootURL: fixture.root, types: [.node], access: .full, filter: filter
        )
        return group?.artifacts ?? []
    }

    @Test("Show all marks a project worked on in the last 6 months Check First")
    func showAllRecentProjectIsCheckFirst() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        try fixture.setDate(now, of: "src/app.js")
        let artifacts = showAllArtifacts(fixture)
        #expect(!artifacts.isEmpty)
        #expect(artifacts.allSatisfy { $0.safetyInfo.level == .medium && $0.checkFirstReason == .usedRecently })
    }

    @Test("a project too big to check is listed as Check First, not hidden")
    func tooBigProjectIsCheckFirst() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        let filter = DevScanner.ProjectListingFilter(
            staleDays: DevToolsStalenessOption.sixMonths.rawValue,
            now: now,
            live: .none,
            activityEntryLimit: 0
        )
        let (group, _) = DevScanner.sizeProjectGroup(
            rootURL: fixture.root, types: [.node], access: .full, filter: filter
        )
        let artifacts = try #require(group?.artifacts)
        #expect(!artifacts.isEmpty)
        #expect(artifacts.allSatisfy { $0.safetyInfo.level == .medium && $0.checkFirstReason == .tooBigToCheck })
    }

    @Test("Show all keeps an old project Safe")
    func showAllOldProjectStaysSafe() throws {
        let fixture = try nodeProject()
        defer { fixture.cleanUp() }
        let artifacts = showAllArtifacts(fixture)
        #expect(!artifacts.isEmpty)
        #expect(artifacts.allSatisfy { $0.safetyInfo.level == .safe && $0.checkFirstReason == nil })
    }
}

@MainActor
@Suite("A project held at Check First stays there after a reset")
struct RecentProjectResetTests {
    private func store(with artifact: ProjectCacheArtifact) -> PurgeStore {
        let store = PurgeStore()
        store.projectGroups = [ProjectGroup(
            displayName: "project",
            rootPath: artifact.projectRoot,
            inferredTypes: [.node],
            artifacts: [artifact]
        )]
        return store
    }

    /// A path that does not exist and that no override can name.
    private func recentArtifact(_ reason: ProjectCheckFirstReason = .usedRecently) -> ProjectCacheArtifact {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("node_modules", isDirectory: true)
        return ProjectCacheArtifact(
            kind: .nodeModules,
            path: path,
            projectRoot: root,
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            safetyInfo: SafetyInfo.forStaleProjectArtifact(kind: .nodeModules, path: path, checkFirstReason: reason),
            reinstallSafety: .notApplicable,
            gitStatus: .clean,
            checkFirstReason: reason
        )
    }

    @Test("Reset to automatic")
    func resetKeepsCheckFirst() {
        let artifact = recentArtifact()
        let store = store(with: artifact)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .medium)
        store.resetProjectArtifactToAutomatic(groupIndex: 0, artifactIndex: 0)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .medium)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test("without recent use, a reset lands on Safe as before")
    func resetWithoutRecentUseIsSafe() {
        var artifact = recentArtifact()
        artifact.checkFirstReason = nil
        let store = store(with: artifact)
        store.resetProjectArtifactToAutomatic(groupIndex: 0, artifactIndex: 0)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .safe)
    }

    @Test("Recategorize")
    func recategorizeKeepsCheckFirst() {
        let store = store(with: recentArtifact())
        store.recategorizeProjectArtifact(groupIndex: 0, artifactIndex: 0)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .medium)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test("a project too big to check stays Check First too")
    func tooBigToCheckSurvivesReset() {
        let store = store(with: recentArtifact(.tooBigToCheck))
        store.resetProjectArtifactToAutomatic(groupIndex: 0, artifactIndex: 0)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .medium)
        store.recategorizeProjectArtifact(groupIndex: 0, artifactIndex: 0)
        #expect(store.projectGroups[0].artifacts[0].safetyInfo.level == .medium)
    }
}

@Suite("Consider stale after uses the 6 months Settings shows until the user changes it")
struct StalenessThresholdDefaultTests {
    @Test("no saved setting means 6 months, not Show all")
    func missingKeyIsSixMonths() {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        #expect(DevToolsStalenessOption.currentThresholdDays(userDefaults: suite.defaults) == 180)
    }

    @Test("no saved setting keeps orphan leftovers at their 30-day buffer")
    func missingKeyKeepsOrphanBuffer() {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        #expect(OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: suite.defaults) == 30)
    }

    @Test("a saved Show all is still Show all")
    func savedShowAllIsKept() {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        suite.defaults.set(DevToolsStalenessOption.showAll.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        #expect(DevToolsStalenessOption.currentThresholdDays(userDefaults: suite.defaults) == 0)
    }

    @Test("with no saved setting, a project edited today is not listed")
    func missingKeyHidesRecentProject() throws {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        let fixture = try ActivityFixture(
            files: ["package.json", "package-lock.json", "src/app.js", "node_modules/pkg/index.js"]
        )
        defer { fixture.cleanUp() }
        try fixture.ageEverything(to: longAgo)
        try fixture.setDate(now, of: "src/app.js")
        let filter = DevScanner.ProjectListingFilter(
            staleDays: DevToolsStalenessOption.currentThresholdDays(userDefaults: suite.defaults),
            now: now,
            live: .none
        )
        let (group, _) = DevScanner.sizeProjectGroup(
            rootURL: fixture.root, types: [.node], access: .full, filter: filter
        )
        #expect(group == nil)
    }
}

@Suite("Process working directories cover every running process")
struct ProcessWorkingDirectoriesTests {
    /// `proc_listallpids` counts pids, not bytes. Read as bytes, the list held about
    /// 1 process in 16, so a project open in a terminal or editor went unseen.
    @Test
    func listReachesBothEndsOfThePidRange() throws {
        let pids = try #require(ProcessWorkingDirectories.allProcessIDs())
        #expect(pids.contains(1))
        #expect(pids.contains(getpid()))
    }

    @Test
    func childProcessWorkingDirectoryIsFound() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.currentDirectoryURL = folder
        try child.run()
        defer { child.terminate() }

        let resolved = folder.resolvingSymlinksInPath().path
        let directories = ProcessWorkingDirectories.allDirectories()
        #expect(directories.contains { $0 == resolved || $0 == "/private" + resolved })
    }
}
