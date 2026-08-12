import Foundation

/// Whether the user has been through onboarding.
///
/// The key was a bare string literal in the views that need it as `@AppStorage`.
/// The launch path now reads it too — a windowless login launch must never skip
/// onboarding — and that caller has no view to hang `@AppStorage` off.
enum OnboardingGate {
    static let userDefaultsKey = "hasCompletedOnboarding"

    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
