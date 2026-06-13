import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    static let userDefaultsKey = "appearance.mode"

    var displayName: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var thumbnailAssetName: String {
        switch self {
        case .system: return "appearance-auto"
        case .light: return "appearance-light"
        case .dark: return "appearance-dark"
        }
    }

    /// `nil` means follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
