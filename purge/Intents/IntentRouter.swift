import Foundation

/// What Purge's App Intents do once they reach the app. The intent types stay
/// thin so the behavior lives here, where tests can drive it with a fake store
/// and without a window.
///
/// Nothing here deletes anything. Every clean and uninstall still ends at the
/// confirm sheet in the window.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter(
        store: AppEnvironment.store,
        reveal: revealWindow,
        onboardingDone: { FirstRunGate.hasCompletedOnboarding }
    )

    private let store: PurgeStore
    private let reveal: @MainActor () -> Void
    private let onboardingDone: @MainActor () -> Bool

    init(
        store: PurgeStore,
        reveal: @escaping @MainActor () -> Void,
        onboardingDone: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.reveal = reveal
        self.onboardingDone = onboardingDone
    }

    /// The person asked for the window, so it is theirs now: a deleted-app review
    /// that ends later must leave it open, the same as opening Purge from the Dock.
    static func revealWindow() {
        RemovedAppMonitor.shared.userOpenedWindow()
        AppWindowPresenter.reveal()
    }

    /// Opens the window on a tab. Before onboarding is done the window shows
    /// onboarding instead, so the tab is left alone.
    func open(tab: PurgeStore.Tab) {
        if onboardingDone() {
            store.selectedTab = tab
        }
        reveal()
    }
}
