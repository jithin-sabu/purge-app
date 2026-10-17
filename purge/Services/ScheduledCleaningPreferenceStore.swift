import Combine
import Foundation
import SwiftUI

private enum UDKeys {
    static let scheduledCleanEnabled = "scheduledClean.enabled"
    static let scheduledEnabledAt = "scheduledClean.enabledAt"
    static let scheduledFrequency = "scheduledClean.frequency"
    static let customIntervalAmount = "scheduledClean.customInterval.amount"
    static let customIntervalUnit = "scheduledClean.customInterval.unit"
}

@MainActor
final class ScheduledCleaningPreferenceStore: ObservableObject {
    static let shared = ScheduledCleaningPreferenceStore()

    private let ud: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            ud.set(isEnabled, forKey: UDKeys.scheduledCleanEnabled)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: self)
        }
    }

    /// When automatic cleaning was last turned on. The registrar anchors the
    /// schedule on the later of this and the last clean, so turning it off and
    /// back on starts a fresh interval instead of running an overdue clean at the
    /// next activation (#173).
    var enabledAt: Date? {
        ud.object(forKey: UDKeys.scheduledEnabledAt) as? Date
    }

    @Published var frequency: ScheduledCleaningFrequency {
        didSet {
            ud.set(frequency.rawValue, forKey: UDKeys.scheduledFrequency)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: self)
        }
    }

    /// Interval for the `.custom` frequency: a count of units (1...365).
    @Published var customIntervalAmount: Int {
        didSet {
            let clamped = min(max(customIntervalAmount, 1), Self.customIntervalAmountLimit)
            if clamped != customIntervalAmount {
                customIntervalAmount = clamped
            }
            ud.set(customIntervalAmount, forKey: UDKeys.customIntervalAmount)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: self)
        }
    }

    /// Unit for the `.custom` frequency: days, weeks, or months.
    @Published var customIntervalUnit: CustomCleaningIntervalUnit {
        didSet {
            ud.set(customIntervalUnit.rawValue, forKey: UDKeys.customIntervalUnit)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: self)
        }
    }

    static let customIntervalAmountLimit = 365

    init(userDefaults: UserDefaults = .standard) {
        ud = userDefaults
        ud.register(defaults: [
            UDKeys.scheduledCleanEnabled: false,
            UDKeys.scheduledFrequency: ScheduledCleaningFrequency.monthly.rawValue,
            UDKeys.customIntervalAmount: 2,
            UDKeys.customIntervalUnit: CustomCleaningIntervalUnit.week.rawValue
        ])
        isEnabled = ud.bool(forKey: UDKeys.scheduledCleanEnabled)
        if let f = ScheduledCleaningFrequency(rawValue: ud.string(forKey: UDKeys.scheduledFrequency) ?? "") {
            frequency = f
        } else {
            frequency = .monthly
        }
        let rawAmount = ud.integer(forKey: UDKeys.customIntervalAmount)
        customIntervalAmount = min(max(rawAmount, 1), Self.customIntervalAmountLimit)
        customIntervalUnit = CustomCleaningIntervalUnit(rawValue: ud.string(forKey: UDKeys.customIntervalUnit) ?? "") ?? .week
    }

    /// The interval the schedule actually runs on: the persisted custom interval
    /// when the frequency is `.custom`, the preset otherwise. Single source of
    /// truth consumed by `ScheduledCleaningRegistrar.dueDate`.
    var effectiveRepeatIntervalSeconds: TimeInterval {
        if frequency == .custom {
            return TimeInterval(customIntervalAmount) * customIntervalUnit.seconds
        }
        return frequency.repeatIntervalSeconds
    }

    func setEnabled(_ enabled: Bool, animation: Animation? = nil) async {
        applyEnabled(enabled, animation: animation)
        if enabled {
            _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()
        }
        Task { await ScheduledCleaningRegistrar.shared.applyScheduleFromPrefs() }
    }

    /// The synchronous half of `setEnabled`: decides whether the schedule restarts,
    /// stamps `enabledAt` if so, then flips `isEnabled`. The stamp lands first
    /// because the flip posts `scheduledCleaningPrefsChanged`, which re-arms the
    /// reminder from the anchor. Tests call this; `setEnabled` adds the
    /// notification permission request and the shared registrar's re-arm, which
    /// a test must never reach (#171).
    func applyEnabled(_ enabled: Bool, now: Date = Date(), animation: Animation? = nil) {
        if Self.restartsSchedule(enabling: enabled, wasEnabled: isEnabled, hasAnchor: enabledAt != nil) {
            restartSchedule(at: now)
        }
        if let animation {
            withAnimation(animation) {
                isEnabled = enabled
            }
        } else {
            isEnabled = enabled
        }
    }

    /// Whether turning automatic cleaning on restarts the schedule: yes from off,
    /// and yes the first time, when there is no anchor yet. A second call while
    /// it is already on leaves the schedule alone.
    nonisolated static func restartsSchedule(enabling: Bool, wasEnabled: Bool, hasAnchor: Bool) -> Bool {
        enabling && (!wasEnabled || !hasAnchor)
    }

    /// Stamps `now` as the moment automatic cleaning was turned on. The next clean
    /// is then one interval from `now`, whatever the schedule did before (#173).
    func restartSchedule(at now: Date = Date()) {
        ud.set(now, forKey: UDKeys.scheduledEnabledAt)
    }
}

extension Notification.Name {
    /// Posted with the store that changed as `object`. Observe one store, never
    /// all of them: tests make stores of their own, and their changes must not
    /// re-arm the user's reminder (#171).
    static let scheduledCleaningPrefsChanged = Notification.Name("ScheduledCleaningPrefsChanged")
}
