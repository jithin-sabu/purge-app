import Foundation
import Testing
@testable import Purge

/// A dev tool is safe to clean whole or not at all (#185). The Overview's safe
/// total once counted a tool unless a path was dirty, while Clean Safe Items took
/// each path git answered clean, so the two disagreed.
@MainActor
@Suite("A dev tool is safe to clean whole or not at all")
struct DevToolWholeToolTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func gradle() -> DevTool {
        let caches = home.appendingPathComponent(".gradle/caches", isDirectory: true)
        let dists = home.appendingPathComponent(".gradle/wrapper/dists", isDirectory: true)
        return DevTool(
            definitionKey: "gradle",
            toolName: "Gradle",
            paths: [caches, dists],
            sizeBytes: 3_000,
            pathSizeBytesByPath: [caches.standardizedFileURL.path: 2_000, dists.standardizedFileURL.path: 1_000],
            isDetected: true,
            safetyInfo: SafetyInfo(level: .safe, headline: "Gradle", explanation: "", recoverySteps: "", reinstallCommand: nil)
        )
    }

    /// Scans the tool with git answering `answers`, and returns the store once
    /// the answers have landed.
    private func scanned(_ fake: FakeScans, answers: [String: GitWorktreeStatus]) async throws -> PurgeStore {
        fake.hasAccess = true
        let tool = gradle()
        // A found tool waits in staging until its size lands.
        fake.developerEvents = [
            .devToolFound(tool),
            .devToolSizeResolved(
                id: tool.id,
                pathSizeBytesByPath: tool.pathSizeBytesByPath,
                sizeBytes: tool.sizeBytes,
                lastModified: .distantPast
            ),
        ]
        fake.gitAnswers = answers
        let store = fake.makeStore()
        await store.scanDeveloper()
        #expect(await eventually {
            store.devTools.count == 1 && tool.standardizedPaths.allSatisfy { store.devToolRepoStatusByPath[$0] != nil }
        })
        try #require(store.devTools.first?.safetyInfo.level == .safe)
        return store
    }

    @Test func aToolWithEveryPathCleanIsCountedAndCleanedWhole() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = try await scanned(fake, answers: [:])

        #expect(store.safeCleanupSummary.devToolBytes == 3_000)
        let paths = Set(store.manualSafeCleanupCandidates().map { $0.path.standardizedFileURL.path })
        #expect(paths == Set(gradle().standardizedPaths))
    }

    @Test func oneDirtyPathKeepsTheWholeToolOut() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = try await scanned(fake, answers: [gradle().standardizedPaths[1]: .dirty])

        #expect(store.safeCleanupSummary.devToolBytes == 0)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test func oneUnknownPathKeepsTheWholeToolOut() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = try await scanned(fake, answers: [gradle().standardizedPaths[0]: .unknown])

        #expect(store.safeCleanupSummary.devToolBytes == 0)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }
}
