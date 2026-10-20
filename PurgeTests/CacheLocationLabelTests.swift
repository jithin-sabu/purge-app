import Foundation
import Testing
@testable import Purge

/// The confirm sheets show each cache folder under its row's title. An app's
/// Application Support cache folders share one row (#231), so each needs a label
/// of its own or the sheet repeats the same two lines for every folder.
/// The paths sit under a made-up home and never exist on disk.
@MainActor
@Suite("Cache location labels")
struct CacheLocationLabelTests {
    private let home = URL(fileURLWithPath: "/private/tmp/PurgeCacheLabelTests-\(UUID().uuidString)", isDirectory: true)

    private func location(_ relative: String, folderName: String) -> CacheLocation {
        CacheLocation(
            path: home.appendingPathComponent(relative, isDirectory: true),
            sizeBytes: 1,
            lastModified: .distantPast,
            folderName: folderName
        )
    }

    private func safetyInfo(_ headline: String) -> SafetyInfo {
        SafetyInfo(level: .safe, headline: headline, explanation: "", recoverySteps: "", reinstallCommand: nil)
    }

    @Test func groupedApplicationSupportFoldersEachShowTheirOwnPath() {
        let item = CacheItem(
            definitionKey: "Claude",
            locations: [
                location("Library/Application Support/Claude/GPUCache", folderName: "Claude"),
                location("Library/Application Support/Claude/Crashpad/completed", folderName: "Claude"),
                location("Library/Application Support/Claude/User Data/Default/Cache", folderName: "Claude"),
            ],
            appName: "Claude AI App",
            safetyInfo: safetyInfo("Claude AI App")
        )

        let candidates = PurgeStore.DeletionCandidate.deletionCandidates(forCache: item)

        #expect(candidates.map(\.subtitle) == ["GPUCache", "Crashpad/completed", "User Data/Default/Cache"])
        #expect(Set(candidates.map(\.title)).count == 1)
    }

    /// Clean Safe Items builds its own candidates, so it needs the same label.
    /// The path sits under the real home so the allowlist offers it, and does not
    /// exist: `Crashpad/completed` is offered by its name alone.
    @Test func cleanSafeItemsShowsTheFolderPathToo() throws {
        let appFolder = "purge-test-\(UUID().uuidString)"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appFolder)/Crashpad/completed", isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: path.path))
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(path))

        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.hasFullDiskAccess = true
        store.cacheItems = [
            CacheItem(
                definitionKey: CacheDiscoveryPaths.applicationSupportGroupKey(appFolderName: appFolder),
                locations: [CacheLocation(path: path, sizeBytes: 1, lastModified: .distantPast, folderName: appFolder)],
                appName: "\(appFolder) Cache",
                safetyInfo: safetyInfo("\(appFolder) Cache"),
                gitStatus: .clean
            ),
        ]

        #expect(store.manualSafeCleanupCandidates().map(\.subtitle) == ["Crashpad/completed"])
    }

    @Test func libraryCachesFolderKeepsItsFolderName() {
        let label = PurgeStore.DeletionCandidate.cacheLocationLabel(
            location("Library/Caches/com.example.app", folderName: "com.example.app")
        )
        #expect(label == "com.example.app")
    }

    @Test func containerCacheKeepsItsBundleID() {
        let label = PurgeStore.DeletionCandidate.cacheLocationLabel(
            location("Library/Containers/com.example.app/Data/Library/Caches", folderName: "com.example.app")
        )
        #expect(label == "com.example.app")
    }

    /// Known cache entries pass their catalog key as the folder name, not the app
    /// folder, so they keep the label they had.
    @Test func knownEntryUnderApplicationSupportKeepsItsKey() {
        let label = PurgeStore.DeletionCandidate.cacheLocationLabel(
            location("Library/Application Support/Code/Cache", folderName: "vscode")
        )
        #expect(label == "vscode")
    }

    @Test func applicationSupportAppFolderItselfKeepsItsName() {
        let label = PurgeStore.DeletionCandidate.cacheLocationLabel(
            location("Library/Application Support/Claude", folderName: "Claude")
        )
        #expect(label == "Claude")
    }
}
