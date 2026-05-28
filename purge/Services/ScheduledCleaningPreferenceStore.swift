import Combine
import Foundation
import SwiftUI

private enum UDKeys {
    static let scheduledCleanEnabled = "scheduledClean.enabled"
    static let scheduledFrequency = "scheduledClean.frequency"
    static let scheduledStaleDays = "scheduledClean.staleDays"
}

@MainActor
final class ScheduledCleaningPreferenceStore: ObservableObject {
    static let shared = ScheduledCleaningPreferenceStore()

    private let ud = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet {
            ud.set(isEnabled, forKey: UDKeys.scheduledCleanEnabled)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
        }
    }

    @Published var frequency: ScheduledCleaningFrequency {
        didSet {
            ud.set(frequency.rawValue, forKey: UDKeys.scheduledFrequency)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
        }
    }

    @Published var unusedDays: ScheduledCleaningUnusedDaysOption {
        didSet {
            ud.set(unusedDays.rawValue, forKey: UDKeys.scheduledStaleDays)
            NotificationCenter.default.post(name: .scheduledCleaningPrefsChanged, object: nil)
        }
    }

    init() {
        ud.register(defaults: [
            UDKeys.scheduledCleanEnabled: false,
            UDKeys.scheduledFrequency: ScheduledCleaningFrequency.monthly.rawValue,
            UDKeys.scheduledStaleDays: ScheduledCleaningUnusedDaysOption.months6.rawValue
        ])
        isEnabled = ud.bool(forKey: UDKeys.scheduledCleanEnabled)
        if let f = ScheduledCleaningFrequency(rawValue: ud.string(forKey: UDKeys.scheduledFrequency) ?? "") {
            frequency = f
        } else {
            frequency = .monthly
        }
        let daysRaw = ud.integer(forKey: UDKeys.scheduledStaleDays)
        let defaultDays = ScheduledCleaningUnusedDaysOption.months6.rawValue
        if let d = ScheduledCleaningUnusedDaysOption(rawValue: daysRaw == 0 ? defaultDays : daysRaw) {
            unusedDays = d
        } else {
            unusedDays = .months6
        }
    }

    func setEnabled(_ enabled: Bool, animation: Animation? = nil) async {
        if let animation {
            withAnimation(animation) {
                isEnabled = enabled
            }
        } else {
            isEnabled = enabled
        }
        if enabled {
            _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()
        }
        Task { await ScheduledCleaningRegistrar.shared.applyScheduleFromPrefs() }
    }

    func updateFrequencyWithoutSideEffects(_ freq: ScheduledCleaningFrequency) {
        frequency = freq
    }
}

extension Notification.Name {
    static let scheduledCleaningPrefsChanged = Notification.Name("ScheduledCleaningPrefsChanged")
}
