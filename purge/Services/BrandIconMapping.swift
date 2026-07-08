import Foundation

/// Maps cache/dev-tool definition keys and project artifact kinds to simple-icons slugs
/// or installed macOS application names for bundle-icon fallback.
enum BrandIconMapping {
    // MARK: - App Caches (explanations.json keys)

    private static let definitionKeyToSlug: [String: String] = [
        "cursor": "cursor",
        "vscode": "visualstudiocode",
        "slack": "slack",
        "discord": "discord",
        "zoom": "zoom",
        "notion": "notion",
        "spotify": "spotify",
        "whatsapp": "whatsapp",
        "telegram": "telegram",
        "telegram-media-cache": "telegram",
        "linear": "linear",
        "figma": "figma",
        "figma-agent": "figma",
        "loom": "loom",
        "grammarly": "grammarly",
        "alfred": "alfred",
        "1password": "1password",
        "dropbox": "dropbox",
        "google-drive": "googledrive",
        "onedrive": "googledrive",
        "microsoft-teams": "microsoftteams",
        "microsoft-word": "microsoftword",
        "microsoft-excel": "microsoftexcel",
        "chrome": "googlechrome",
        "firefox": "firefox",
        "brave": "brave",
        "opera": "opera",
        "arc-browser": "arc",
        "zen": "zenbrowser",
        "safari": "safari",
        "raycast": "raycast",
        "warp-terminal": "warp",
        "iterm2": "iterm2",
        "ghostty": "ghostty",
        "datadog": "datadog",
        "sentry": "sentry",
        "cleanmymac": "macpaw",
        "bartender": "bartender",
        "cleanshot": "cleanshot",
        "sketch": "sketch",
        "affinity-designer": "affinitydesigner",
        "affinity-photo": "affinityphoto",
        "proxyman": "proxyman",
        "tableplus": "tableplus",
        "postico": "postico",
        "insomnia": "insomnia",
        "paw-rapi": "paw",
        "fork-git": "fork",
        "sourcetree": "sourcetree",
        "tower-git": "tower",
        "android-studio": "androidstudio",
        "xcode-app": "xcode",
        "claude-app": "anthropic",
        "chatgpt-app": "openai",
        "perplexity-updater": "perplexity",
        "ollama": "ollama",
        "granola": "granola",
        "screenflow": "screenflow",
        "lungo": "lungo",
        "docker": "docker",
        "jetbrains": "jetbrains",
        "zed": "zed",
        "electron": "electron",
        "ms-playwright": "playwright",
        "cloudkit": "icloud",
        "cloudd": "icloud",
        "bird": "icloud",
        "icloud-notification-agent": "icloud",
        "cloud-telemetry": "icloud",
        "DerivedData": "xcode",
        "archives": "xcode",
        "xcode-archives": "xcode",
        "xcode-device-support": "xcode",
        "xcode-itunes-service": "xcode",
    ]

    /// Keys with no simple-icons PNG; resolve via installed app bundle only.
    private static let bundleOnlyDefinitionKeys: Set<String> = [
        "ghostty", "proxyman", "postico", "fork-git", "tower-git", "cleanshot",
        "bartender", "granola", "lungo", "tableplus", "paw-rapi", "screenflow",
        "vscode", "microsoft-teams", "microsoft-word", "microsoft-excel",
        "onedrive",
    ]

    /// Installed `.app` name under /Applications when bundle ID lookup is unavailable.
    private static let definitionKeyToApplicationName: [String: String] = [
        "cursor": "Cursor",
        "vscode": "Visual Studio Code",
        "ghostty": "Ghostty",
        "proxyman": "Proxyman",
        "postico": "Postico",
        "tableplus": "TablePlus",
        "fork-git": "Fork",
        "tower-git": "Tower",
        "cleanshot": "CleanShot X",
        "bartender": "Bartender 5",
        "granola": "Granola",
        "lungo": "Lungo",
        "screenflow": "ScreenFlow",
        "paw-rapi": "Paw",
        "microsoft-teams": "Microsoft Teams",
        "microsoft-word": "Microsoft Word",
        "microsoft-excel": "Microsoft Excel",
        "onedrive": "OneDrive",
        "DerivedData": "Xcode",
        "archives": "Xcode",
        "xcode-archives": "Xcode",
        "xcode-device-support": "Xcode",
        "xcode-app": "Xcode",
        "iOS DeviceSupport": "Xcode",
        "android-studio": "Android Studio",
        "cleanmymac": "CleanMyMac",
    ]

    private static let definitionKeyToBundleID: [String: String] = [
        "DerivedData": "com.apple.dt.Xcode",
        "archives": "com.apple.dt.Xcode",
        "xcode-archives": "com.apple.dt.Xcode",
        "xcode-device-support": "com.apple.dt.Xcode",
        "xcode-app": "com.apple.dt.Xcode",
        "iOS DeviceSupport": "com.apple.dt.Xcode",
    ]

    // MARK: - Dev Tools global rows

    private static let devToolDefinitionKeyToSlug: [String: String] = [
        "npm-cache": "nodedotjs",
        "npm": "nodedotjs",
        "pnpm-store": "nodedotjs",
        "pnpm": "nodedotjs",
        "yarn-cache": "nodedotjs",
        "yarn": "nodedotjs",
        "homebrew-cache": "homebrew",
        "homebrew": "homebrew",
        "docker": "docker",
        "gradle-cache": "android",
        "gradle": "android",
        "cocoapods-cache": "swift",
        "cocoapods": "swift",
        "cargo": "rust",
        "go": "go",
        "maven": "openjdk",
        "sbt": "scala",
        "rubygems": "ruby",
        "bundler": "ruby",
        "composer": "php",
        "terraform": "terraform",
        "githubactions": "github",
        "vagrant": "vagrant",
        "gitworktrees": "git",
        "vscode": "visualstudiocode",
        "cursor": "cursor",
        "jetbrains": "jetbrains",
        "zed": "zed",
        "electron": "electron",
        "DerivedData": "xcode",
        "archives": "xcode",
        "xcode": "xcode",
        "xcode-device-support": "xcode",
        "iOS DeviceSupport": "xcode",
        "swiftpm": "swift",
        "flutter": "flutter",
        "flutter-cache": "flutter",
        "android-sdk": "androidstudio",
        "xcode-archives": "xcode",
        "xcode-app": "xcode",
    ]

  // MARK: - Project artifact kinds

    private static let artifactKindToSlug: [DeletableArtifactKind: String] = [
        .nodeModules: "nodedotjs",
        .venv: "python",
        .dotGradle: "android",
        .target: "rust",
        .pods: "swift",
        .dartTool: "flutter",
        .flutterBuild: "flutter",
    ]

    private static let projectTypeToSlug: [ProjectType: String] = [
        .node: "nodedotjs",
        .rust: "rust",
        .flutter: "flutter",
        .xcode: "swift",
        .python: "python",
        .androidGradle: "android",
    ]

    /// Future path-pattern → slug (frontend toolchain bucket uses React per spec).
    static let pathPatternToSlug: [(pattern: String, slug: String)] = [
        ("node_modules", "nodedotjs"),
        ("npm", "nodedotjs"),
        ("yarn", "nodedotjs"),
        ("pnpm", "nodedotjs"),
        ("bun", "nodedotjs"),
        ("deno", "nodedotjs"),
        (".next", "react"),
        ("vite", "react"),
        ("parcel", "react"),
        ("turbo", "react"),
        ("nx", "react"),
        ("storybook", "react"),
        ("eslint", "react"),
        ("jest", "react"),
        ("vitest", "react"),
        ("husky", "react"),
        (".dart_tool", "flutter"),
        ("pub-cache", "flutter"),
        ("flutter", "flutter"),
        ("__pycache__", "python"),
        ("uv", "python"),
        ("ruff", "python"),
        ("mypy", "python"),
        ("cargo", "rust"),
        ("target", "rust"),
        ("go/pkg/mod", "go"),
        ("go-build", "go"),
        (".gradle", "android"),
        ("kotlin", "kotlin"),
        (".gem", "ruby"),
        ("bundler", "ruby"),
        ("composer", "php"),
        ("swift", "swift"),
        ("cocoapods", "swift"),
        (".sbt", "scala"),
        (".ivy2", "scala"),
        ("terraform", "terraform"),
        ("docker", "docker"),
        ("github", "github"),
        ("vagrant", "vagrant"),
        ("homebrew", "homebrew"),
        ("git", "git"),
        ("maven", "openjdk"),
    ]

    static func slug(forDefinitionKey key: String) -> String? {
        let lower = key.lowercased()
        if let slug = definitionKeyToSlug[lower] ?? definitionKeyToSlug[key] {
            return slug
        }
        if let slug = devToolDefinitionKeyToSlug[lower] ?? devToolDefinitionKeyToSlug[key] {
            return slug
        }
        return nil
    }

    static func slug(forArtifactKind kind: DeletableArtifactKind) -> String? {
        artifactKindToSlug[kind]
    }

    static func slug(forProjectType type: ProjectType) -> String? {
        projectTypeToSlug[type]
    }

    static func slug(forPathComponent name: String) -> String? {
        let lower = name.lowercased()
        for entry in pathPatternToSlug {
            if lower.contains(entry.pattern.lowercased()) {
                return entry.slug
            }
        }
        return nil
    }

    static func isBundleOnlyDefinitionKey(_ key: String) -> Bool {
        bundleOnlyDefinitionKeys.contains(key) || bundleOnlyDefinitionKeys.contains(key.lowercased())
    }

    static func preferredApplicationName(forDefinitionKey key: String) -> String? {
        definitionKeyToApplicationName[key]
            ?? definitionKeyToApplicationName[key.lowercased()]
    }

    static func preferredBundleID(forDefinitionKey key: String) -> String? {
        if let id = definitionKeyToBundleID[key] ?? definitionKeyToBundleID[key.lowercased()] {
            return id
        }
        return ExplanationDatabase.allBundleIDs(forKey: key).first
    }
}
