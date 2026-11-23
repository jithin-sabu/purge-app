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
        "claude-updater": "anthropic",
        "openai-codex": "openai",
    ]

    // MARK: - Dev Tools global rows

    private static let devToolDefinitionKeyToSlug: [String: String] = [
        "npm-cache": "nodedotjs",
        "npm": "nodedotjs",
        "pnpm-store": "pnpm",
        "pnpm": "pnpm",
        "yarn-cache": "yarn",
        "yarn": "yarn",
        "homebrew-cache": "homebrew",
        "homebrew": "homebrew",
        "docker": "docker",
        "gradle-cache": "gradle",
        "gradle-global-cache": "gradle",
        "gradle": "gradle",
        "cocoapods-cache": "swift",
        "cocoapods-spec-repos": "swift",
        "cocoapods": "swift",
        "cargo": "rust",
        "go": "go",
        "go-build-cache": "go",
        "maven": "openjdk",
        "sbt": "scala",
        "rubygems": "ruby",
        "bundler": "ruby",
        "composer": "composer",
        "terraform": "terraform",
        "githubactions": "github",
        "vagrant": "vagrant",
        "gitworktrees": "git",
        "cursor": "cursor",
        "jetbrains": "jetbrains",
        "zed": "zedindustries",
        "electron": "electron",
        "ms-playwright": "playwright",
        "playwright-unused-builds": "playwright",
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
        "orphaned-editor-workspace-storage": "cursor",
        "cursor-agent-leftover": "cursor",
        "cursor-agent-install-leftovers": "cursor",
        "vite-plus-node-install-leftovers": "vite",
        "claude-code-downloads": "anthropic",
        "android-system-images": "androidstudio",
        "old-figma-profiles": "figma",
        "orphaned-git-worktree": "git",
        // Tools with a glyph in the bundle that their rows did not use.
        "bun-cache": "bun",
        "deno-cache": "deno",
        "turbo-cache": "turbo",
        "nextjs-cache": "nextdotjs",
        "next-build": "nextdotjs",
        "vite-cache": "vite",
        "eslint-cache": "eslint",
        "jest-cache": "jest",
        "vitest-cache": "vitest",
        "storybook-cache": "storybook",
        "nx-cache": "nx",
        "python-cache": "python",
        "pytest-cache": "python",
        "mypy-cache": "python",
        "tox-environments": "python",
        "venv": "python",
        "apple-python-cache": "python",
        "uv-cache": "uv",
        "ruff-cache": "ruff",
        "kotlin-build": "kotlin",
        "android-build": "android",
        "gradle-build": "gradle",
        "gradle-leftovers": "gradle",
        "maven-target": "openjdk",
        "swift-build": "swift",
        "swiftpm-build": "swift",
        "swiftpm-cache": "swift",
        "swift-frontend-cache": "swift",
        "rust-target": "rust",
        "nvm-cache": "nodedotjs",
        "nvm-download-cache": "nodedotjs",
        "node-modules": "nodedotjs",
        "checkpoint-nodejs": "nodedotjs",
        "node-gyp-headers": "nodedotjs",
        "dart-tool": "flutter",
        "pub-cache": "flutter",
        "bundler-vendor": "ruby",
        "composer-vendor": "php",
        "terraform-plugins": "terraform",
        "claude-cli-cache": "anthropic",
        "cursor-compile-cache": "cursor",
    ]

    // MARK: - Brands with no glyph

    /// Brands Simple Icons doesn't carry: Microsoft had its logos removed, and the
    /// smaller apps were never added. Their rows show the installed app's icon in
    /// greyscale, found by the definition's bundle IDs first and then by this name.
    /// A definition whose bundle IDs name an installed app needs no entry here.
    private static let definitionKeyToApplicationName: [String: String] = [
        "vscode": "Visual Studio Code",
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
        "yab": "Yab",
    ]

    /// Apps whose icon a definition borrows, by bundle ID, when its own
    /// `bundle_ids` name a background service rather than the app. Only the icon
    /// comes from here: `explanations.json` bundle IDs also match folders, these never do.
    private static let definitionKeyToIconBundleIDs: [String: [String]] = [
        "maps-tile-cache": ["com.apple.Maps"],
        "messages-previews": ["com.apple.MobileSMS"],
        "mail-downloads": ["com.apple.mail"],
        "findmy": ["com.apple.findmy"],
        "homed": ["com.apple.Home"],
        "remindd": ["com.apple.reminders"],
        "tipsd": ["com.apple.helpviewer"],
        "helpd": ["com.apple.helpviewer"],
        "videoconference": ["com.apple.FaceTime"],
        "itunes": ["com.apple.Music"],
        "amp-library-agent": ["com.apple.Music"],
        "dictionary-services": ["com.apple.Dictionary"],
        "assistantd": ["com.apple.siri.launcher"],
        "siri-tts": ["com.apple.siri.launcher"],
        "parsecd": ["com.apple.siri.launcher"],
        "duetexpertd": ["com.apple.siri.launcher"],
        "proactive-eventtracker": ["com.apple.siri.launcher"],
        "appstoreagent": ["com.apple.AppStore"],
        "amsaccountsd": ["com.apple.AppStore"],
        "amsengagementd": ["com.apple.AppStore"],
        "ams-migrator": ["com.apple.AppStore"],
        "promoted-content": ["com.apple.AppStore"],
        "app-installation-binary-deltas": ["com.apple.AppStore"],
        "fileprovider-appstore": ["com.apple.AppStore"],
        "gamed": ["com.apple.games"],
        "gamekit": ["com.apple.games"],
        "davinci-cacheclip": ["com.blackmagic-design.DaVinciResolve"],
    ]

  // MARK: - Project artifact kinds

    private static let artifactKindToSlug: [DeletableArtifactKind: String] = [
        .nodeModules: "nodedotjs",
        .venv: "python",
        .dotGradle: "gradle",
        .target: "rust",
        .pods: "swift",
        .dartTool: "flutter",
        .flutterBuild: "flutter",
        // These came from matching the artifact's path, which also read the
        // user's own folder names (#183).
        .nextBuild: "nextdotjs",
        .viteCache: "vite",
        .turboCache: "turbo",
        .parcelCache: "react",
        .pytestCache: "python",
        .mypyCache: "python",
        .ruffCache: "ruff",
        .toxEnvironments: "python",
        .swiftPMBuild: "swift",
        .mavenTarget: "openjdk",
        .gradleBuild: "gradle",
        .composerVendor: "php",
        .bundlerVendor: "ruby",
        .terraformPlugins: "terraform",
    ]

    private static let projectTypeToSlug: [ProjectType: String] = [
        .node: "nodedotjs",
        .rust: "rust",
        .flutter: "flutter",
        .xcode: "swift",
        .python: "python",
        .androidGradle: "android",
    ]

    /// Folder name → slug for project rows. A tool with its own glyph uses it; the
    /// rest of the frontend toolchain uses React.
    static let pathPatternToSlug: [(pattern: String, slug: String)] = [
        ("node_modules", "nodedotjs"),
        ("npm", "nodedotjs"),
        ("yarn", "yarn"),
        ("pnpm", "pnpm"),
        ("bun", "bun"),
        ("deno", "deno"),
        (".next", "nextdotjs"),
        ("vite", "vite"),
        ("parcel", "react"),
        ("turbo", "turbo"),
        ("nx", "nx"),
        ("storybook", "storybook"),
        ("eslint", "eslint"),
        ("jest", "jest"),
        ("vitest", "vitest"),
        ("husky", "react"),
        (".dart_tool", "flutter"),
        ("pub-cache", "flutter"),
        ("flutter", "flutter"),
        ("__pycache__", "python"),
        ("uv", "uv"),
        ("ruff", "ruff"),
        ("mypy", "python"),
        ("cargo", "rust"),
        ("target", "rust"),
        ("go/pkg/mod", "go"),
        ("go-build", "go"),
        (".gradle", "gradle"),
        ("kotlin", "kotlin"),
        (".gem", "ruby"),
        ("bundler", "ruby"),
        ("composer", "composer"),
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
        // Each NDK row's key is its label, `Android NDK <version>` (#324).
        if OldToolVersionScanPolicy.ndkVersion(inLabel: key) != nil {
            return "androidstudio"
        }
        // Each nvm Node row's key is its label, `nvm Node.js <version>` (#400).
        if NvmNodeVersionPolicy.version(inLabel: key) != nil {
            return "nodedotjs"
        }
        // Each Vite+ Node row's key is its label, `Vite+ Node.js <version>` (#398).
        if VitePlusNodeVersionPolicy.version(inLabel: key) != nil {
            return "vite"
        }
        // Each rustup row's key is its label, `rustup toolchain <folder name>` (#406).
        if RustupToolchainPolicy.toolchain(inLabel: key) != nil {
            return "rust"
        }
        // Each uv Python row's key is its label, `uv Python <folder name>` (#405).
        if UvPythonVersionPolicy.folder(inLabel: key) != nil {
            return "python"
        }
        // Each pyenv row's key is its label, `pyenv Python <version>` (#404).
        if PyenvPythonVersionPolicy.version(inLabel: key) != nil {
            return "python"
        }
        return nil
    }

    /// The installed app to borrow an icon from, for a brand with no glyph.
    static func applicationName(forDefinitionKey key: String) -> String? {
        definitionKeyToApplicationName[key] ?? definitionKeyToApplicationName[key.lowercased()]
    }

    static func iconBundleIDs(forDefinitionKey key: String) -> [String] {
        definitionKeyToIconBundleIDs[key] ?? definitionKeyToIconBundleIDs[key.lowercased()] ?? []
    }

    static func slug(forArtifactKind kind: DeletableArtifactKind) -> String? {
        artifactKindToSlug[kind]
    }

    static func slug(forProjectType type: ProjectType) -> String? {
        projectTypeToSlug[type]
    }

    /// The whole folder name must equal a pattern. A substring match found
    /// "nx" in `phoenix` and "bun" in `bunny`, and was tried on the whole path
    /// too, so the user's own folder names picked the icon (#183).
    static func slug(forPathComponent name: String) -> String? {
        let lower = name.lowercased()
        return pathPatternToSlug.first { $0.pattern.lowercased() == lower }?.slug
    }
}
