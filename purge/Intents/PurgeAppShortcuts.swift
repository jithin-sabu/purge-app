import AppIntents

/// Three actions, on purpose: the jobs people reach for from Spotlight or Siri
/// are checking for junk, cleaning it, and removing an app. Opening a tab, a
/// separate "how much" answer and a size for Shortcuts are left out: each adds
/// a choice without saving a step. Every phrase names the app, since App
/// Shortcuts only match that way; Spotlight also matches the search keywords
/// on each action, which need no app name.
nonisolated struct PurgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanForJunkIntent(),
            phrases: [
                "Scan for junk with \(.applicationName)",
                "Find junk with \(.applicationName)",
                "Free up space with \(.applicationName)",
                "Clean up my Mac with \(.applicationName)",
                "How much can \(.applicationName) free",
                "How much space can \(.applicationName) free up",
                "Check my storage with \(.applicationName)",
                "Scan my Mac with \(.applicationName)",
                "\(.applicationName) scan",
            ],
            shortTitle: "Scan for Junk",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: CleanSafeJunkIntent(),
            phrases: [
                "Clean junk with \(.applicationName)",
                "Clean safe junk with \(.applicationName)",
                "Clear junk with \(.applicationName)",
                "Clear caches with \(.applicationName)",
                "Delete junk with \(.applicationName)",
                "\(.applicationName) clean",
            ],
            shortTitle: "Clean Safe Junk",
            systemImageName: "trash.fill"
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
