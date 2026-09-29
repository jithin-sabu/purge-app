import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("What granting Full Disk Access found")
struct LockedPlacesFindingsTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func candidate(_ relative: String, bytes: Int64) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: relative,
            path: home.appendingPathComponent(relative),
            sizeBytes: bytes,
            safetyInfo: SafetyInfo(level: .safe, headline: relative, explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    /// Counting by location means a cache the limited scan already saw never
    /// counts, however much it grew back since.
    @Test
    func onlyItemsInLockedPlacesCount() {
        let findings = LockedPlacesFindings.from(candidates: [
            candidate("Library/Caches/com.example.app", bytes: 900),
            candidate("Library/Containers/com.example.sandboxed/Data/Library/Caches", bytes: 300),
            candidate("Documents/app/node_modules", bytes: 200),
        ]) { locked in
            [OnboardingResultsCategory(title: "Locked", symbol: "lock", bytes: locked.reduce(0) { $0 + $1.sizeBytes })]
        }

        #expect(findings.bytes == 500)
        #expect(findings.categories.first?.bytes == 500)
    }

    @Test
    func smallFindingsDoNotLead() {
        let small = LockedPlacesFindings(bytes: 80 * 1024 * 1024, categories: [])
        let large = LockedPlacesFindings(bytes: 6 * 1024 * 1024 * 1024, categories: [])
        #expect(!small.isWorthLeadingWith)
        #expect(large.isWorthLeadingWith)
    }

    /// A scan cut off by its time cap has not looked everywhere yet, so it must
    /// not report that nothing was hiding.
    @Test
    func partialScanDoesNotClaimNothingWasHiding() {
        var nothing = LockedPlacesFindings(bytes: 0, categories: [])
        #expect(LookDeeperView.smallFindingsMessage(nothing).contains("Nothing big was hiding"))

        nothing.isPartial = true
        let message = LookDeeperView.smallFindingsMessage(nothing)
        #expect(!message.contains("Nothing big was hiding"))
        #expect(message.contains("still checking"))
    }

    @Test
    func grantCountsOnceAndOnlyAfterRecordedDenial() throws {
        let suite = "purge-tests-access-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PurgeStore()

        // First launch ever: nothing recorded, so no grant to announce.
        store.hasFullDiskAccess = false
        #expect(!store.consumeFullDiskAccessGrant(userDefaults: defaults))

        store.hasFullDiskAccess = true
        #expect(store.consumeFullDiskAccessGrant(userDefaults: defaults))
        // The look-deeper screen and the app both call this; only one may announce.
        #expect(!store.consumeFullDiskAccessGrant(userDefaults: defaults))
    }

    @Test
    func installThatAlwaysHadAccessNeverAnnouncesAGrant() throws {
        let suite = "purge-tests-access-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PurgeStore()

        store.hasFullDiskAccess = true
        #expect(!store.consumeFullDiskAccessGrant(userDefaults: defaults))
        #expect(!store.consumeFullDiskAccessGrant(userDefaults: defaults))
    }
}
