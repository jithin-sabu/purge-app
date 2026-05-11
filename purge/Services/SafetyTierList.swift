import Foundation

enum SafetyTierList {

    /// Folders we are 100% certain are safe to delete.
    /// These are always regenerated automatically with zero data loss.
    nonisolated static let definitelySafe: Set<String> = [
        "node_modules",
        "DerivedData",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        "__pycache__",
        ".gradle",
        "target",
        "build",
        "dist",
        "out",
        ".cache",
        "venv",
        ".venv",
        "_cacache",
        "Homebrew",
        "yarn",
        "pnpm",
        "pip",
        "cocoapods",
        "Pods"
    ]

    /// Bundle ID prefixes we are certain are safe app caches.
    /// These are standard app cache folders that apps recreate automatically.
    nonisolated static let definitelySafeBundlePrefixes: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.spotify.client",
        "com.tinyspeck.slackmacgap",
        "com.figma.desktop",
        "us.zoom.xos",
        "com.microsoft.VSCode",
        "com.todesktop",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "notion.id",
        "com.linear",
        "com.loom.desktop",
        "com.grammarly",
        "com.ollama.ollama",
        "com.microsoft.teams"
    ]

    /// Folders that involve user data or syncing.
    /// Safe to delete technically but may cause inconvenience.
    nonisolated static let checkFirst: Set<String> = [
        "com.apple.mail",
        "com.apple.Photos",
        "com.apple.Music",
        "com.apple.Maps",
        "com.apple.GeoServices",
        "com.dropbox.client2",
        "com.google.GoogleDrive",
        "com.google.drivefs",
        "com.microsoft.OneDrive",
        "com.apple.cloudd",
        "com.1password.1password",
        "com.apple.icloud"
    ]

    /// Folders that must never be deleted.
    /// These contain credentials, passwords, or critical system data.
    nonisolated static let doNotDelete: Set<String> = [
        "Keychains",
        "Preferences",
        "Application Support",
        "Mail",
        "AddressBook",
        "CallHistoryDB",
        "com.apple.TCC"
    ]

    nonisolated static func evaluate(folderName: String) -> SafetyLevel? {
        let lower = folderName.lowercased()

        // Check do not delete first
        if doNotDelete.contains(where: { lower == $0.lowercased() }) {
            return .danger
        }

        // Check definitely safe folder names
        if definitelySafe.contains(where: { lower == $0.lowercased() }) {
            return .safe
        }

        // Check definitely safe bundle ID prefixes
        for prefix in definitelySafeBundlePrefixes where lower.hasPrefix(prefix.lowercased()) {
            return .safe
        }

        // Check check first
        if checkFirst.contains(where: { lower == $0.lowercased() }) {
            return .medium
        }

        // Unknown, let AI decide
        return nil
    }
}
