import Foundation

enum ScheduledCleaningFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case quarterly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 months"
        }
    }

    /// Seconds between repeats (local notification + graceful activation sweep).
    var repeatIntervalSeconds: TimeInterval {
        switch self {
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        case .quarterly: return 90 * 24 * 60 * 60
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
        case .oneMonth: return "1 month"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .twelveMonths: return "12 months"
        case .twoYears: return "2 years"
        case .showAll: return "Show all"
        }
    }

    var description: String {
        switch self {
        case .showAll:
            return "All detected project folders will appear in Developer Projects regardless of when they were last used."
        case .oneMonth, .threeMonths, .sixMonths, .twelveMonths, .twoYears:
            return "Project folders not touched within this period are considered stale and will appear in Developer Projects for cleanup. Choose Show all to see every detected project regardless of age."
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
