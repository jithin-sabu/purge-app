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

    private func item(_ name: String, appName: String, folders: [String], bytes: Int64) -> CacheItem {
        CacheItem(
            definitionKey: "test-\(name)",
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

    private func bytes(_ title: String, in categories: [OnboardingResultsCategory]) -> Int64? {
        categories.first { $0.title == title }?.bytes
    }

    @Test func candidatesAreSortedByTheRowThatHoldsThem() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [
            item("browser", appName: "Example Browser", folders: ["browser/Cache", "browser/Code Cache"], bytes: 1),
            item("app", appName: "Example App", folders: ["app/Cache"], bytes: 1),
        ]

        let categories = store.resultsCategories(for: [
            candidate("browser/Cache", bytes: 300),
            candidate("browser/Code Cache", bytes: 200),
            candidate("app/Cache", bytes: 400),
            candidate("project/node_modules", bytes: 900),
        ])

        #expect(bytes(String(localized: "Browser caches"), in: categories) == 500)
        #expect(bytes(String(localized: "App caches"), in: categories) == 400)
        #expect(bytes(PurgeStore.devArtifactCategoryTitle, in: categories) == 900)
        #expect(categories.map(\.bytes) == [900, 500, 400])
    }

    /// Two rows can list one folder. The first row in the list decides, as it did
    /// when every row was searched in order.
    @Test func theFirstRowHoldingAPathWins() {
        let scans = FakeScans()
        let store = scans.makeStore()
        store.cacheItems = [
            item("app", appName: "Example App", folders: ["shared/Cache"], bytes: 1),
            item("browser", appName: "Example Browser", folders: ["shared/Cache"], bytes: 1),
        ]

        let categories = store.resultsCategories(for: [candidate("shared/Cache", bytes: 700)])

        #expect(bytes(String(localized: "App caches"), in: categories) == 700)
        #expect(bytes(String(localized: "Browser caches"), in: categories) == nil)
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

        #expect(bytes(String(localized: "App caches"), in: categories) == 250)
    }
}
