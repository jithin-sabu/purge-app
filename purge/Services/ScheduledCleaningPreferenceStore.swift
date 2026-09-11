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
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
        }
    }

    /// Timestamp of when automatic cleaning was first enabled and not yet cleared.
    /// Survives toggling off/on so the next-clean anchor is a pause/resume, not a restart.
    var enabledAt: Date? {
        ud.object(forKey: UDKeys.scheduledEnabledAt) as? Date
    }

    @Published var frequency: ScheduledCleaningFrequency {
        didSet {
            ud.set(frequency.rawValue, forKey: UDKeys.scheduledFrequency)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
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
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
        }
    }

    /// Unit for the `.custom` frequency: days, weeks, or months.
    @Published var customIntervalUnit: CustomCleaningIntervalUnit {
        didSet {
            ud.set(customIntervalUnit.rawValue, forKey: UDKeys.customIntervalUnit)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
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
        if let animation {
            withAnimation(animation) {
                isEnabled = enabled
            }
        } else {
            isEnabled = enabled
        }
        // Anchor the schedule the first time it's enabled; never clear it on disable
        // so toggling off then on resumes against the same anchor.
        if enabled, enabledAt == nil {
            ud.set(Date(), forKey: UDKeys.scheduledEnabledAt)
        }
        if enabled {
            _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()
        }
        Task { await ScheduledCleaningRegistrar.shared.applyScheduleFromPrefs() }
    }
}

extension Notification.Name {
    static let scheduledCleaningPrefsChanged = Notification.Name("ScheduledCleaningPrefsChanged")
}
