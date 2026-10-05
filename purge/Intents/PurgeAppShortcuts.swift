import AppIntents

/// The actions Spotlight, Siri and the Shortcuts app offer without any setup.
/// Every phrase names the app; App Shortcuts are only matched that way.
nonisolated struct PurgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPurgeTabIntent(),
            phrases: [
                "Open \(\.$tab) in \(.applicationName)",
                "Show \(\.$tab) in \(.applicationName)",
                "Open \(.applicationName) to \(\.$tab)",
            ],
            shortTitle: "Open Tab",
            systemImageName: "macwindow"
        )
    }
}
