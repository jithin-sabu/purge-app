import Foundation
import Testing
@testable import Purge

/// The onboarding results sort each candidate into a category by the cache row that
/// holds its path. It now looks rows up by path instead of searching them all for
/// every candidate (#190).
@Suite("Onboarding results categories")
@MainActor
struct OnboardingResultsCategoriesTests {
    private let base = URL(fileURLWithPath: "/private/tmp/purge-onboarding-categories-test", isDirectory: true)
    private let safe = SafetyInfo(level: .safe, headline: "Cache", explanation: "x", recoverySteps: "", reinstallCommand: nil)

    private func item(_ name: String, key: String? = nil, appName: String, folders: [String], bytes: Int64) -> CacheItem {
        CacheItem(
            definitionKey: key ?? "test-\(name)",
            locations: folders.map {
                CacheLocation(
                    path: base.appendingPathComponent($0, isDirectory: true),
                    sizeBytes: bytes,
                    lastModified: Date(timeIntervalSince1970: 1_600_000_000),
                    folderName: name
                )
            },
            appName: appName,
            safetyInfo: safe
        )
    }

    private func candidate(_ folder: String, bytes: Int64) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: folder,
            path: base.appendingPathComponent(folder, isDirectory: true),
            sizeBytes: bytes,
            safetyInfo: safe,
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    private func bytes(_ kind: OnboardingResultsCategory.Kind, in categories: [OnboardingResultsCategory]) -> Int64? {
        categories.first { $0.kind == kind }?.bytes
    }

    @Test func candidatesAreSortedByTheRowThatHoldsThem() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [
            item("browser", key: "chrome", appName: "Example Browser", folders: ["browser/Cache", "browser/Code Cache"], bytes: 1),
            item("app", appName: "Example App", folders: ["app/Cache"], bytes: 1),
        ]

        let categories = store.resultsCategories(for: [
            candidate("browser/Cache", bytes: 300),
            candidate("browser/Code Cache", bytes: 200),
            candidate("app/Cache", bytes: 400),
            candidate("project/node_modules", bytes: 900),
        ])

        #expect(bytes(.browserCaches, in: categories) == 500)
        #expect(bytes(.appCaches, in: categories) == 400)
        #expect(bytes(.devArtifacts, in: categories) == 900)
        #expect(categories.map(\.bytes) == [900, 500, 400])
    }

    /// Two rows can list one folder. The first row in the list decides, as it did
    /// when every row was searched in order.
    @Test func theFirstRowHoldingAPathWins() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [
            item("app", appName: "Example App", folders: ["shared/Cache"], bytes: 1),
            item("browser", key: "chrome", appName: "Example Browser", folders: ["shared/Cache"], bytes: 1),
        ]

        let categories = store.resultsCategories(for: [candidate("shared/Cache", bytes: 700)])

        #expect(bytes(.appCaches, in: categories) == 700)
        #expect(bytes(.browserCaches, in: categories) == nil)
    }

    /// Row names are translated, so a name never makes a row a browser. Only the
    /// row's definition, or the folder it was found by, does (#183).
    @Test func aBrowserIsKnownByItsDefinitionNotItsName() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [
            item("named", appName: "Example Browser", folders: ["named/Cache"], bytes: 1),
            item("chrome", key: "chrome", appName: "谷歌浏览器", folders: ["chrome/Cache"], bytes: 1),
            CacheItem(
                definitionKey: nil,
                location: CacheLocation(
                    path: base.appendingPathComponent("stale/Cache", isDirectory: true),
                    sizeBytes: 1,
                    lastModified: Date(timeIntervalSince1970: 1_600_000_000),
                    folderName: "stale-browser-framework"
                ),
                appName: "旧版浏览器框架",
                safetyInfo: safe
            ),
        ]

        let categories = store.resultsCategories(for: [
            candidate("named/Cache", bytes: 100),
            candidate("chrome/Cache", bytes: 200),
            candidate("stale/Cache", bytes: 300),
        ])

        #expect(bytes(.appCaches, in: categories) == 100)
        #expect(bytes(.browserCaches, in: categories) == 500)
    }

    /// Two rows can list one folder, and the clean moves it once. The sidebar
    /// total, the onboarding number and its rows all count it once too (#183).
    @Test func aSharedFolderIsCountedOnceEverywhere() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let store = scans.makeStore()
        let shared = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/purge-test-\(UUID().uuidString)", isDirectory: true)
        func row(_ key: String) -> CacheItem {
            CacheItem(
                definitionKey: key,
                locations: [CacheLocation(path: shared, sizeBytes: 700, lastModified: .distantPast, folderName: key)],
                appName: key,
                safetyInfo: safe,
                gitStatus: .clean
            )
        }
        store.cacheItems = [row("test-first"), row("test-second")]

        let candidates = store.manualSafeCleanupCandidates()
        let snapshot = store.onboardingResultsSnapshot
        #expect(candidates.map(\.sizeBytes) == [700])
        #expect(store.safeCleanupSummary.totalBytes == 700)
        #expect(snapshot.totalBytes == 700)
        #expect(snapshot.categories.map(\.bytes).reduce(0, +) == 700)
    }

    /// The candidate's path may be spelled differently from the stored one.
    @Test func pathsAreComparedStandardized() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [item("app", appName: "Example App", folders: ["app/Cache"], bytes: 1)]

        let unstandardized = PurgeStore.DeletionCandidate(
            title: "Cache",
            path: base.appendingPathComponent("app/./other/../Cache", isDirectory: true),
            sizeBytes: 250,
            safetyInfo: safe,
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
        let categories = store.resultsCategories(for: [unstandardized])

        #expect(bytes(.appCaches, in: categories) == 250)
    }
}
