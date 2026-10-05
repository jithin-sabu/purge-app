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
        AppShortcut(
            intent: ScanMacIntent(),
            phrases: [
                "Scan my Mac with \(.applicationName)",
                "Scan with \(.applicationName)",
                "\(.applicationName) scan",
            ],
            shortTitle: "Scan My Mac",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: UninstallAppIntent(),
            phrases: [
                "Uninstall \(\.$app) with \(.applicationName)",
                "Remove \(\.$app) with \(.applicationName)",
                "Uninstall an app with \(.applicationName)",
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
