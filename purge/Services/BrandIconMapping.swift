import Foundation

/// Maps cache/dev-tool definition keys and project artifact kinds to Simple Icons
/// slugs. Brands Simple Icons doesn't carry use their installed app's icon instead;
/// anything else falls back to its definition's `CacheKind` symbol.
enum BrandIconMapping {
    // MARK: - App Caches (explanations.json keys)

    private static let definitionKeyToSlug: [String: String] = [
        "cursor": "cursor",
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
        "sketch": "sketch",
        "affinity-designer": "affinitydesigner",
        "affinity-photo": "affinityphoto",
        "insomnia": "insomnia",
        "sourcetree": "sourcetree",
        "tower-git": "tower",
        "android-studio": "androidstudio",
        "xcode-app": "xcode",
        "claude-app": "anthropic",
        "chatgpt-app": "openai",
        "perplexity-updater": "perplexity",
        "ollama": "ollama",
        "docker": "docker",
        "jetbrains": "jetbrains",
        "zed": "zedindustries",
        "electron": "electron",
        "ms-playwright": "playwright",
        "adobe-media-cache-files": "adobe",
        "adobe-media-cache": "adobe",
        "adobe-camera-raw": "adobe",
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
        "cursor": "cursor",
        "jetbrains": "jetbrains",
        "zed": "zedindustries",
        "electron": "electron",
        "ms-playwright": "playwright",
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
        "xcode-docs-cache": "xcode",
        "npm-npx-cache": "nodedotjs",
        "npm-logs": "nodedotjs",
        "corepack-cache": "nodedotjs",
        "obsolete-cursor-extension": "cursor",
        "cursor-agent-leftover": "cursor",
        "zsh": "iterm2",
    ]

    // MARK: - Brands with no glyph

    /// Brands Simple Icons doesn't carry: Microsoft had its logos removed, and the
    /// smaller apps were never added. Their rows show the installed app's icon in
    /// greyscale, found by the definition's bundle IDs first and then by this name.
    private static let definitionKeyToApplicationName: [String: String] = [
        "vscode": "Visual Studio Code",
        "obsolete-vscode-extension": "Visual Studio Code",
        "microsoft-teams": "Microsoft Teams",
        "microsoft-word": "Microsoft Word",
        "microsoft-excel": "Microsoft Excel",
        "onedrive": "OneDrive",
        "proxyman": "Proxyman",
        "postico": "Postico",
        "tableplus": "TablePlus",
        "paw-rapi": "Paw",
        "fork-git": "Fork",
        "cleanshot": "CleanShot X",
        "screenflow": "ScreenFlow",
        "bartender": "Bartender 5",
        "lungo": "Lungo",
        "granola": "Granola",
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

    /// The installed app to borrow an icon from, for a brand with no glyph.
    static func applicationName(forDefinitionKey key: String) -> String? {
        definitionKeyToApplicationName[key] ?? definitionKeyToApplicationName[key.lowercased()]
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
}
