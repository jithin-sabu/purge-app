import Foundation
import Testing
@testable import Purge

@Suite("Custom cleaning interval")
@MainActor
struct CustomCleaningIntervalTests {
    /// Each test gets its own defaults suite so the persistent domain starts genuinely empty.
    private func makeStore() -> (ScheduledCleaningPreferenceStore, UserDefaults, String) {
        let name = "io.getpurge.tests.custominterval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (ScheduledCleaningPreferenceStore(userDefaults: defaults), defaults, name)
    }

    private func cleanup(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Unit seconds", arguments: [
        (CustomCleaningIntervalUnit.day, TimeInterval(86_400)),
        (CustomCleaningIntervalUnit.week, TimeInterval(604_800)),
        (CustomCleaningIntervalUnit.month, TimeInterval(2_592_000)),
    ])
    func unitSeconds(unit: CustomCleaningIntervalUnit, expected: TimeInterval) {
        #expect(unit.seconds == expected)
    }

    @Test("Interval phrase singular and plural")
    func intervalPhrase() {
        #expect(CustomCleaningIntervalUnit.day.phrase(amount: 1) == "day")
        #expect(CustomCleaningIntervalUnit.week.phrase(amount: 2) == "2 weeks")
        #expect(CustomCleaningIntervalUnit.month.phrase(amount: 3) == "3 months")
    }

    @Test("Preset intervals are unchanged", arguments: [
        (ScheduledCleaningFrequency.weekly, TimeInterval(7 * 86_400)),
        (ScheduledCleaningFrequency.monthly, TimeInterval(30 * 86_400)),
        (ScheduledCleaningFrequency.quarterly, TimeInterval(90 * 86_400)),
    ])
    func presetIntervals(frequency: ScheduledCleaningFrequency, expected: TimeInterval) {
        let (store, defaults, name) = makeStore()
        defer { cleanup(defaults, name: name) }

        store.frequency = frequency
        #expect(store.effectiveRepeatIntervalSeconds == expected)
    }

    @Test("Custom interval is amount times unit")
    func customInterval() {
        let (store, defaults, name) = makeStore()
        defer { cleanup(defaults, name: name) }

        store.frequency = .custom
        store.customIntervalAmount = 14
        store.customIntervalUnit = .day
        #expect(store.effectiveRepeatIntervalSeconds == 14 * 86_400)

        store.customIntervalAmount = 1
        store.customIntervalUnit = .month
        #expect(store.effectiveRepeatIntervalSeconds == 2_592_000)
    }

    @Test("Custom amount is clamped to 1...365")
    func amountClamping() {
        let (store, defaults, name) = makeStore()
        defer { cleanup(defaults, name: name) }

        store.frequency = .custom
        store.customIntervalUnit = .day
        store.customIntervalAmount = 0
        #expect(store.customIntervalAmount == 1)

        store.customIntervalAmount = 1_000
        #expect(store.customIntervalAmount == ScheduledCleaningPreferenceStore.customIntervalAmountLimit)
        #expect(store.effectiveRepeatIntervalSeconds == TimeInterval(365 * 86_400))
    }

    @Test("Custom interval persists to defaults")
    func customIntervalPersists() {
        let (store, defaults, name) = makeStore()
        defer { cleanup(defaults, name: name) }

        store.customIntervalAmount = 45
        store.customIntervalUnit = .day

        #expect(defaults.integer(forKey: "scheduledClean.customInterval.amount") == 45)
        #expect(defaults.string(forKey: "scheduledClean.customInterval.unit") == "day")

        let reloaded = ScheduledCleaningPreferenceStore(userDefaults: defaults)
        #expect(reloaded.customIntervalAmount == 45)
        #expect(reloaded.customIntervalUnit == .day)
    }

    @Test("Custom frequency decodes from its raw value")
    func customFrequencyDecodes() {
        #expect(ScheduledCleaningFrequency(rawValue: "custom") == .custom)
        #expect(ScheduledCleaningFrequency.custom.displayName == "Custom")
    }

    @Test("Unknown legacy frequency falls back to monthly")
    func unknownFrequencyFallsBack() {
        let (store, defaults, name) = makeStore()
        defer { cleanup(defaults, name: name) }

        defaults.set("not-a-frequency", forKey: "scheduledClean.frequency")
        let reloaded = ScheduledCleaningPreferenceStore(userDefaults: defaults)
        #expect(reloaded.frequency == .monthly)
    }
}
