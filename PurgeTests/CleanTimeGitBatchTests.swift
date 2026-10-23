import Foundation
import Testing
@testable import Purge

/// Records how many `git status` reads overlap, and answers dirty for chosen repos.
private actor OverlapGit {
    private var active = 0
    private(set) var maxActive = 0
    private(set) var reads: [String] = []
    private let dirty: Set<String>

    init(dirty: Set<String>) {
        self.dirty = dirty
    }

    func read(_ repository: URL) async -> GitWorktreeStatus {
        active += 1
        maxActive = max(maxActive, active)
        reads.append(repository.lastPathComponent)
        try? await Task.sleep(for: .milliseconds(150))
        active -= 1
        return dirty.contains(repository.lastPathComponent) ? .dirty : .clean
    }
}

/// The delete confirmation fills in git status for all its candidates with one
/// check, so unrelated repositories overlap instead of waiting in turn (#190).
@Suite("Clean-time git checks")
@MainActor
struct CleanTimeGitBatchTests {
    private func makeRepositories(_ names: [String]) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-git-batch-\(UUID().uuidString)", isDirectory: true)
        for name in names {
            let repo = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repo.appendingPathComponent("notes"), withIntermediateDirectories: true)
        }
        return parent
    }

    private func candidate(_ path: URL, git: GitWorktreeStatus = .unknown) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: path.lastPathComponent,
            path: path,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: .medium, headline: "Notes", explanation: "x", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: git
        )
    }

    @Test func candidatesInSeveralRepositoriesAreCheckedTogether() async throws {
        let names = ["alpha", "bravo", "charlie", "delta"]
        let parent = try makeRepositories(names)
        defer { try? FileManager.default.removeItem(at: parent) }
        let git = OverlapGit(dirty: ["charlie"])
        let scans = FakeScans()
        let store = scans.makeStore(gitChecker: GitStatusChecker(readStatus: { await git.read($0) }))

        let candidates = names.map { candidate(parent.appendingPathComponent("\($0)/notes", isDirectory: true)) }
        await store.presentDeletionSheetResolvingGit(candidates: candidates)

        let statuses = Dictionary(uniqueKeysWithValues: store.deletionCandidatesForSheet.map { ($0.path.deletingLastPathComponent().lastPathComponent, $0.gitStatus) })
        #expect(statuses == ["alpha": .clean, "bravo": .clean, "charlie": .dirty, "delta": .clean])
        #expect(await git.reads.sorted() == names)
        #expect(await git.maxActive > 1)
        store.dismissDeletionSheet()
    }

    /// Clean Safe Items and scheduled cleans move only what git answered clean for.
    /// The answers now come from one batch, so a path missing from it must not count
    /// as clean.
    @Test func safeCleanTakesOnlyCleanAnswers() {
        let base = URL(fileURLWithPath: "/private/tmp/purge-git-filter-test", isDirectory: true)
        let clean = candidate(base.appendingPathComponent("clean/notes", isDirectory: true))
        let dirty = candidate(base.appendingPathComponent("dirty/notes", isDirectory: true))
        let unknown = candidate(base.appendingPathComponent("unknown/notes", isDirectory: true))
        let unanswered = candidate(base.appendingPathComponent("unanswered/notes", isDirectory: true))
        let statuses: [String: GitWorktreeStatus] = [
            clean.path.standardizedFileURL.path: .clean,
            dirty.path.standardizedFileURL.path: .dirty,
            unknown.path.standardizedFileURL.path: .unknown,
        ]

        let kept = PurgeStore.gitCleanCandidates([clean, dirty, unknown, unanswered], statuses: statuses)

        #expect(kept.map(\.path) == [clean.path])
    }

    /// A candidate that already knows its status is not asked again.
    @Test func knownStatusesAreKept() async throws {
        let parent = try makeRepositories(["alpha", "bravo"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let git = OverlapGit(dirty: ["alpha", "bravo"])
        let scans = FakeScans()
        let store = scans.makeStore(gitChecker: GitStatusChecker(readStatus: { await git.read($0) }))

        await store.presentDeletionSheetResolvingGit(candidates: [
            candidate(parent.appendingPathComponent("alpha/notes", isDirectory: true), git: .clean),
            candidate(parent.appendingPathComponent("bravo/notes", isDirectory: true)),
        ])

        #expect(store.deletionCandidatesForSheet.map(\.gitStatus) == [.clean, .dirty])
        #expect(await git.reads == ["bravo"])
        store.dismissDeletionSheet()
    }
}
