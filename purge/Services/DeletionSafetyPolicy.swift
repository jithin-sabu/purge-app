import Foundation

/// Outcome of running a candidate path through the safety policy.
enum DeletionSafetyDecision: Equatable {
    /// Safe to remove.
    case allow
    /// On the never-delete list. Skip silently and drop from any selection.
    case blockedNeverDelete
    /// Not on the whitelist. Skip and surface "This file was skipped for safety".
    case blockedNotWhitelisted

    var skipReason: String? {
        switch self {
        case .allow: return nil
        case .blockedNeverDelete: return "Protected location — not eligible for deletion."
        case .blockedNotWhitelisted: return "This file was skipped for safety"
        }
    }

    var isUserVisibleSkip: Bool {
        self == .blockedNotWhitelisted
    }
}

/// Strict allow / deny policy gating every filesystem removal performed by Purge.
/// Both manual and scheduled cleanup must run paths through `evaluate(_:)` before
/// touching the disk. Any path not explicitly allowed is refused.
enum DeletionSafetyPolicy {
    /// Folder names allowed to be removed when located anywhere inside the user's home.
    nonisolated static let whitelistedFolderNames: Set<String> = [
        "node_modules",
        "venv",
        ".venv",
        "target",
        "Pods",
        ".gradle",
        "DerivedData",
        "build",
        "dist",
        "out",
        ".next",
        ".nuxt",
        ".cache",
        "__pycache__",
        ".turbo",
        ".parcel-cache"
    ]

    /// Sensitive locations whose path or any descendant must never be removed.
    nonisolated static func neverDeletePrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Keychains",
            "\(home)/Library/Preferences",
            "\(home)/Library/Application Support",
            "\(home)/Library/Mail",
            "\(home)/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var"
        ]
    }

    /// User content roots that themselves are off-limits, while whitelisted caches
    /// nested below them remain reachable through the whitelist.
    nonisolated static func neverDeleteExactPaths(home: String) -> [String] {
        [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Music",
            "\(home)/Movies"
        ]
    }

    /// Absolute paths (and their descendants) we are explicitly authorized to delete.
    nonisolated static func whitelistedAbsolutePrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/.npm",
            "\(home)/.yarn/cache",
            "\(home)/.pnpm-store",
            "\(home)/.gradle/caches",
            "\(home)/.cargo/registry",
            "\(home)/.pub-cache"
        ]
    }

    nonisolated static func evaluate(_ url: URL) -> DeletionSafetyDecision {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let home = homeURL.path

        for blocked in neverDeletePrefixes(home: home) {
            if path == blocked || path.hasPrefix(blocked + "/") {
                return .blockedNeverDelete
            }
        }

        if neverDeleteExactPaths(home: home).contains(path) {
            return .blockedNeverDelete
        }

        for allowed in whitelistedAbsolutePrefixes(home: home) {
            if path == allowed || path.hasPrefix(allowed + "/") {
                return .allow
            }
        }

        let inHome = path == home || path.hasPrefix(home + "/")
        if inHome && whitelistedFolderNames.contains(standardized.lastPathComponent) {
            return .allow
        }

        return .blockedNotWhitelisted
    }
}
