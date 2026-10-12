import Foundation
import Testing
@testable import Purge

@Suite("The Apple Intelligence row only acts where it was checked, and always offers a way back")
struct AppleIntelligenceModelStoreTests {
    private func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    /// The spike ran on 27.0. A new major version could rename the service's
    /// keys, and a release the service reads as naming no sets resets every
    /// asset on the Mac, so 28 stays out until it is checked.
    @Test func supportedOnEvery27ReleaseOnly() {
        #expect(AppleIntelligenceModelStore.isSupported(os: os(27), machine: "arm64"))
        #expect(AppleIntelligenceModelStore.isSupported(os: os(27, 3), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(26, 6), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(15, 5), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(28), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(27), machine: "x86_64"))
    }

    private func reading(present: Int) -> AppleIntelligenceReading {
        let sets = AppleIntelligenceCatalog.sets.enumerated().map { index, set in
            AppleIntelligenceSetReading(
                set: set,
                recordsOnDisk: index < present ? 3 : 0,
                eliminating: 0,
                latestBytes: index < present ? 1_000_000_000 : 0,
                folder: index < present ? .holdsFiles : .empty
            )
        }
        return AppleIntelligenceReading(sets: sets, readAt: Date())
    }

    /// After a partial removal the block is installed and some sets stayed.
    /// Download Again is the only way in the app to lift the block, so it shows
    /// beside Remove.
    @Test func partialRemovalOffersBothActions() {
        let offers = AppleIntelligenceModelStore.offers(reading: reading(present: 2), isProfileInstalled: true)
        #expect(offers.remove)
        #expect(offers.downloadAgain)
    }

    @Test func otherStatesOfferOneAction() {
        let untouched = AppleIntelligenceModelStore.offers(reading: reading(present: 5), isProfileInstalled: false)
        #expect(untouched.remove && !untouched.downloadAgain)

        let removed = AppleIntelligenceModelStore.offers(reading: reading(present: 0), isProfileInstalled: true)
        #expect(!removed.remove && removed.downloadAgain)

        let none = AppleIntelligenceModelStore.offers(reading: reading(present: 0), isProfileInstalled: false)
        #expect(!none.remove && none.downloadAgain)

        let unread = AppleIntelligenceModelStore.offers(reading: nil, isProfileInstalled: false)
        #expect(!unread.remove && !unread.downloadAgain)
    }

    /// One set can start minutes after the one before it, so the watch does not
    /// end after a short pause; and it does not say "downloading" forever when
    /// nothing comes.
    @Test func downloadWatchWaitsForAQuietSpellAndGivesUpWhenNothingComes() {
        let settle = AppleIntelligenceModelStore.downloadSettleTime
        let start = AppleIntelligenceModelStore.downloadStartWait
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: true, quietFor: 60) == .keepWatching)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: true, quietFor: settle) == .settled)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: false, quietFor: settle) == .keepWatching)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: false, quietFor: start) == .nothingArrived)
    }

    /// After a partial removal some sets are on the Mac before Download Again,
    /// so those must not count as arrivals, or the watch would call a download
    /// that never started finished.
    @Test func setsAlreadyThereAtTheRequestAreNotArrivals() {
        let leftovers = reading(present: 2).sets
        #expect(!AppleIntelligenceModelStore.hasArrivals(since: leftovers, now: leftovers))
        #expect(AppleIntelligenceModelStore.hasArrivals(since: leftovers, now: reading(present: 3).sets))
        #expect(AppleIntelligenceModelStore.hasArrivals(since: reading(present: 0).sets, now: reading(present: 1).sets))
        #expect(!AppleIntelligenceModelStore.hasArrivals(since: reading(present: 0).sets, now: reading(present: 0).sets))
    }
}
