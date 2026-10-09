import Foundation

enum ScheduledCleaningFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case quarterly
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return String(localized: "Weekly")
        case .monthly: return String(localized: "Monthly")
        case .quarterly: return String(localized: "Every 3 months")
        case .custom: return String(localized: "Custom")
        }
    }

    /// Seconds between repeats (local notification + graceful activation sweep).
    /// For `.custom` this is a fallback only — the engine reads the persisted
    /// interval via `ScheduledCleaningPreferenceStore.effectiveRepeatIntervalSeconds`.
    var repeatIntervalSeconds: TimeInterval {
        switch self {
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        case .quarterly: return 90 * 24 * 60 * 60
        case .custom: return 30 * 24 * 60 * 60
        }
    }
}

enum CustomCleaningIntervalUnit: String, Codable, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: return String(localized: "Days")
        case .week: return String(localized: "Weeks")
        case .month: return String(localized: "Months")
        }
    }

    var singularDisplayName: String {
        switch self {
        case .day: return String(localized: "Day")
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        }
    }

    /// "every X" phrase for this unit at the given amount, e.g. "day" or "2 weeks".
    func phrase(amount: Int) -> String {
        amount == 1
            ? singularDisplayName.lowercased()
            : "\(amount) \(displayName.lowercased())"
    }

    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }
}

enum DevToolsStalenessOption: Int, Codable, CaseIterable, Identifiable {
    case oneMonth = 30
    case threeMonths = 90
    case sixMonths = 180
    case twelveMonths = 365
    case twoYears = 730
    case showAll = 0

    static let userDefaultsKey = "devTools.stalenessThreshold"
    static let defaultOption: DevToolsStalenessOption = .sixMonths

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMonth: return String(localized: "1 month")
        case .threeMonths: return String(localized: "3 months")
        case .sixMonths: return String(localized: "6 months")
        case .twelveMonths: return String(localized: "12 months")
        case .twoYears: return String(localized: "2 years")
        case .showAll: return String(localized: "Show all")
        }
    }

    var description: String {
        switch self {
        case .showAll:
            return String(localized: "All detected projects appear in Developer Projects regardless of when they were last used, except ones in use right now.")
        case .oneMonth, .threeMonths, .sixMonths, .twelveMonths, .twoYears:
            return String(localized: "Projects you have not worked on within this period appear in Developer Projects for cleanup. Editing any file or using git in a project counts as working on it, and a project in use right now never appears. Choose Show all to see every detected project regardless of age.")
        }
    }

    nonisolated static func currentThresholdDays(userDefaults: UserDefaults = .standard) -> Int {
        let raw = userDefaults.integer(forKey: userDefaultsKey)
        if raw == showAll.rawValue {
            return showAll.rawValue
        }
        return DevToolsStalenessOption(rawValue: raw)?.rawValue ?? defaultOption.rawValue
    }
}
