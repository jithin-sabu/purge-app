import Foundation

/// Hidden developer mode, unlocked by tapping the app icon on the About page
/// five times. Gates internal verification affordances (like the scheduled
/// clean "Run now" button) that regular users shouldn't see.
enum DeveloperMode {
    static let userDefaultsKey = "developerMode.enabled"

    /// Number of taps on the About icon required to toggle developer mode.
    static let unlockTapCount = 5

    /// Whether developer mode is currently enabled.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
