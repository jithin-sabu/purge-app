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
                "Go to \(\.$tab) in \(.applicationName)",
                "Show my \(\.$tab) in \(.applicationName)",
            ],
            shortTitle: "Open Tab",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: ScanMacIntent(),
            phrases: [
                "Scan my Mac with \(.applicationName)",
                "Scan with \(.applicationName)",
                "\(.applicationName) scan",
                "Clean up my Mac with \(.applicationName)",
                "Free up space with \(.applicationName)",
                "Find junk with \(.applicationName)",
                "Check my storage with \(.applicationName)",
                "What can \(.applicationName) clean",
            ],
            shortTitle: "Scan My Mac",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: UninstallAppIntent(),
            phrases: [
                // Phrases with the app expand once per installed app, and the
                // system caps the total, so only two of them name the app.
                "Uninstall \(\.$app) with \(.applicationName)",
                "Remove \(\.$app) with \(.applicationName)",
                "Uninstall an app with \(.applicationName)",
                "Remove an app with \(.applicationName)",
                "Delete an app with \(.applicationName)",
                "Get rid of an app with \(.applicationName)",
            ],
            shortTitle: "Uninstall an App",
            systemImageName: "trash"
        )
    }
}

extension PurgeAppShortcuts {
    /// Re-reads the installed apps behind "Uninstall <app> with Purge". Here so
    /// callers need not import AppIntents.
    static func refreshAppList() {
        updateAppShortcutParameters()
    }
}
