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

enum ScheduledCleaningUnusedDaysOption: Int, Codable, CaseIterable, Identifiable {
    case days30 = 30
    case days60 = 60
    case days90 = 90
    case months6 = 180
    case months12 = 365

    /// Minimum staleness for developer artifacts in scheduled cleaning (6× user threshold, floored here).
    static let developerArtifactFloorDays = 180

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .days30: return "30 days"
        case .days60: return "60 days"
        case .days90: return "90 days"
        case .months6: return "6 months"
        case .months12: return "12 months"
        }
    }

    var summaryDurationPhrase: String { label }

    /// User-facing threshold for app caches in scheduled cleaning.
    var cacheStaleDays: Int { rawValue }

    /// Internal threshold for project artifacts and global dev tool folders (6× selection, 6-month floor).
    var developerArtifactStaleDays: Int {
        max(Self.developerArtifactFloorDays, rawValue * 6)
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
