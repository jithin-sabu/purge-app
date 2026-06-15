import Foundation
import SwiftUI

enum SafetyLevel: String, CaseIterable, Codable, Hashable {
    case safe
    case medium
    case danger
    case unknown

    var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .medium: return 1
        case .danger: return 2
        case .unknown: return 3
        }
    }

    var displayName: String {
        switch self {
        case .safe: return "Safe to Clean"
        case .medium: return "Check First"
        case .danger: return "Do Not Delete"
        case .unknown: return "Not Sure"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .medium: return .orange
        case .danger: return .red
        case .unknown: return .gray
        }
    }

    var symbolName: String {
        symbolName(filled: true)
    }

    func symbolName(filled: Bool) -> String {
        switch self {
        case .safe: return filled ? "checkmark.circle.fill" : "checkmark.circle"
        case .medium: return filled ? "questionmark.circle.fill" : "questionmark.circle"
        case .danger: return filled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
        case .unknown: return filled ? "questionmark.circle.fill" : "questionmark.circle"
        }
    }
}

struct SafetyInfo: Hashable {
    let level: SafetyLevel
    let headline: String
    let explanation: String
    let recoverySteps: String
    let reinstallCommand: String?
}
