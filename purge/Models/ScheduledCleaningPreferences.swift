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

    var id: Int { rawValue }

    var label: String { "\(rawValue) days" }
}
