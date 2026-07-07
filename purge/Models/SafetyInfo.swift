import Foundation
import SwiftUI

/// The classification a scanned item can carry.
///
/// There are exactly two *risk tiers* that are eligible to surface in scan
/// results: `.safe` ("Safe to Clean") and `.medium` ("Check First"). There is
/// deliberately no "Do Not Delete" tier — dangerous paths (e.g. iPhone/iPad
/// backups) are simply never placed on the allowlist, so they are never scanned
/// and never classified. `.unknown` ("Not Sure") is not a risk tier; it is the
/// fallback for a folder the resolver could not identify, and such items are
/// dropped at the scan-results assembly boundary (see
/// `canSurfaceInScanResults`).
enum SafetyLevel: String, CaseIterable, Codable, Hashable {
    case safe
    case medium
    case unknown

    /// The only classifications permitted to surface in scan results. Anything
    /// else is dropped at the assembly boundary as a safety net, so a future
    /// allowlist or classification mistake can never leak a non-eligible item
    /// into the UI.
    var canSurfaceInScanResults: Bool {
        self == .safe || self == .medium
    }

    var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .medium: return 1
        case .unknown: return 3
        }
    }

    var displayName: String {
        switch self {
        case .safe: return "Safe to Clean"
        case .medium: return "Check First"
        case .unknown: return "Not Sure"
        }
    }

    var color: Color {
        switch self {
        case .safe: return AppColors.tagSafeText
        case .medium: return AppColors.tagCheckText
        case .unknown: return AppColors.tagUnsureText
        }
    }

    var symbolName: String {
        symbolName(filled: true)
    }

    func symbolName(filled: Bool) -> String {
        switch self {
        case .safe: return filled ? "checkmark.circle.fill" : "checkmark.circle"
        case .medium: return filled ? "questionmark.circle.fill" : "questionmark.circle"
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
