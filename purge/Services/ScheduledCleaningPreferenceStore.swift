import Combine
import Foundation
import SwiftUI

private enum UDKeys {
    static let scheduledCleanEnabled = "scheduledClean.enabled"
    static let scheduledEnabledAt = "scheduledClean.enabledAt"
    static let scheduledFrequency = "scheduledClean.frequency"
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

    init() {
        ud.register(defaults: [
            UDKeys.scheduledCleanEnabled: false,
            UDKeys.scheduledFrequency: ScheduledCleaningFrequency.monthly.rawValue
        ])
        isEnabled = ud.bool(forKey: UDKeys.scheduledCleanEnabled)
        if let f = ScheduledCleaningFrequency(rawValue: ud.string(forKey: UDKeys.scheduledFrequency) ?? "") {
            frequency = f
        } else {
            frequency = .monthly
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
