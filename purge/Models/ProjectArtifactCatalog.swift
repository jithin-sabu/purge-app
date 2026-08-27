import Foundation

/// How a removed artifact is brought back.
nonisolated enum ReinstallInstruction: Hashable, Sendable {
    /// Shell command run from the project root. `{root}` is substituted with the path.
    case command(String)
    /// Plain-English steps, for ecosystems with no single reliable command.
    case guidance(String)
    /// npm/pnpm/yarn, chosen by which lockfile is present.
    case nodePackageManager
    /// `pod install`, run from wherever the Podfile actually lives.
    case cocoaPods
    case none
}

/// One removable folder belonging to one kind of project.
///
/// This table is the single source of truth for project artifacts: what identifies
/// the project, which folder is removable, how it comes back, and how risky removing
/// it is. Adding an ecosystem means adding rows here and an `explanations.json` entry,
/// with no new switch statements to keep in sync.
///
/// Safety note: a rule here only ever *proposes* a path. Every proposal is still put
/// through `DeletionSafetyPolicy.isOfferedForCleanup`, so a rule cannot widen what the
/// app is allowed to delete. It can only narrow it.
nonisolated struct ProjectArtifactRule: Hashable, Sendable {
    let kind: DeletableArtifactKind
    let projectType: ProjectType

    /// Folder to remove, relative to the project root. May contain a subdirectory
    /// (`ios/Pods`, `project/target`).
    let folder: String

    /// Any one of these, relative to the project root, must exist for the rule to fire.
    let rootMarkers: [String]

    /// File extensions that identify the project when no fixed filename does
    /// (`.csproj`, `.cabal`, `.tf`, `.uproject`). Checked by listing the root.
    let rootMarkerExtensions: [String]

    /// Any one of these must exist for a clean rebuild, resolved relative to the
    /// artifact's own parent directory (`..` is allowed and standardized). Empty
    /// means `rebuildMarkers` alone is enough.
    let lockfiles: [String]

    /// Evidence that a rebuild is possible at all, resolved like `lockfiles`.
    /// Empty means no evidence is required.
    let rebuildMarkers: [String]

    /// Filenames that, if found *inside* the artifact folder, disqualify it entirely.
    /// This is for folders that are usually disposable but sometimes hold real state.
    let refuseWhenPresent: [String]

    let reinstall: ReinstallInstruction

    /// `.safe` participates in one-click and scheduled cleaning. `.medium` ("Check
    /// First") is shown but never auto-selected, which is the right tier for anything
    /// that technically rebuilds itself but costs the user real time when it does.
    let level: SafetyLevel

    init(
        kind: DeletableArtifactKind,
        projectType: ProjectType,
        folder: String,
        rootMarkers: [String],
        rootMarkerExtensions: [String] = [],
        lockfiles: [String] = [],
        rebuildMarkers: [String] = [],
        refuseWhenPresent: [String] = [],
        reinstall: ReinstallInstruction,
        level: SafetyLevel = .safe
    ) {
        self.kind = kind
        self.projectType = projectType
        self.folder = folder
        self.rootMarkers = rootMarkers
        self.rootMarkerExtensions = rootMarkerExtensions
        self.lockfiles = lockfiles
        self.rebuildMarkers = rebuildMarkers
        self.refuseWhenPresent = refuseWhenPresent
        self.reinstall = reinstall
        self.level = level
    }
}

extension ProjectArtifactRule {
    /// Whether `root` really is a project this rule applies to.
    nonisolated func matchesRoot(_ root: URL) -> Bool {
        let fm = FileManager.default
        if rootMarkers.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) {
            return true
        }
        guard !rootMarkerExtensions.isEmpty else { return false }
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return false
        }
        let wanted = Set(rootMarkerExtensions.map { $0.lowercased() })
        return children.contains { wanted.contains($0.pathExtension.lowercased()) }
    }

    /// Whether this particular folder holds something that must not be thrown away,
    /// even though folders of this kind normally can be.
    nonisolated func refusesArtifact(at url: URL) -> Bool {
        guard !refuseWhenPresent.isEmpty else { return false }
        let fm = FileManager.default
        return refuseWhenPresent.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }
}

nonisolated enum ProjectArtifactCatalog {

    // MARK: - Rules

    /// Ordering is cosmetic only; lookups are by kind or project type.
    nonisolated static let rules: [ProjectArtifactRule] = [

        // MARK: JavaScript / TypeScript

        .init(
            kind: .nodeModules, projectType: .node, folder: "node_modules",
            rootMarkers: ["package.json"],
            lockfiles: ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml"],
            rebuildMarkers: ["package.json"],
            reinstall: .nodePackageManager
        ),
        // Framework output folders. Purge's safety list already permitted these; until
        // now nothing ever looked for them, so they were allowed and invisible.
        .init(kind: .nextBuild, projectType: .node, folder: ".next",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .nuxtBuild, projectType: .node, folder: ".nuxt",
              rootMarkers: ["nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        // `.output` is the loosest folder name in the table, so it is anchored on a Nuxt
        // config rather than on `package.json` like its siblings.
        .init(kind: .nuxtOutput, projectType: .node, folder: ".output",
              rootMarkers: ["nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .svelteKitBuild, projectType: .node, folder: ".svelte-kit",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .astroBuild, projectType: .node, folder: ".astro",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .angularCache, projectType: .node, folder: ".angular",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .turboCache, projectType: .node, folder: ".turbo",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .parcelCache, projectType: .node, folder: ".parcel-cache",
              rootMarkers: ["package.json"], rebuildMarkers: ["package.json"],
              reinstall: .nodePackageManager),
        .init(kind: .viteCache, projectType: .node, folder: "node_modules/.vite",
              rootMarkers: ["package.json"], rebuildMarkers: ["../package.json"],
              reinstall: .nodePackageManager),

        // MARK: Rust

        .init(kind: .target, projectType: .rust, folder: "target",
              rootMarkers: ["Cargo.toml"], rebuildMarkers: ["Cargo.toml"],
              reinstall: .command("cd \"{root}\" && cargo build")),

        // MARK: Python

        .init(kind: .venv, projectType: .python, folder: "venv",
              rootMarkers: ["requirements.txt", "pyproject.toml"],
              rebuildMarkers: ["requirements.txt", "pyproject.toml"],
              reinstall: .guidance("Use your usual steps to recreate the Python environment for this folder.")),
        .init(kind: .venv, projectType: .python, folder: ".venv",
              rootMarkers: ["requirements.txt", "pyproject.toml"],
              rebuildMarkers: ["requirements.txt", "pyproject.toml"],
              reinstall: .guidance("Use your usual steps to recreate the Python environment for this folder.")),
        .init(kind: .pytestCache, projectType: .python, folder: ".pytest_cache",
              rootMarkers: ["requirements.txt", "pyproject.toml"],
              reinstall: .guidance("Recreated automatically the next time you run your tests.")),
        .init(kind: .mypyCache, projectType: .python, folder: ".mypy_cache",
              rootMarkers: ["requirements.txt", "pyproject.toml"],
              reinstall: .guidance("Recreated automatically the next time you run mypy.")),
        .init(kind: .ruffCache, projectType: .python, folder: ".ruff_cache",
              rootMarkers: ["requirements.txt", "pyproject.toml"],
              reinstall: .guidance("Recreated automatically the next time you run ruff.")),
        .init(kind: .toxEnvironments, projectType: .python, folder: ".tox",
              rootMarkers: ["tox.ini"],
              reinstall: .command("cd \"{root}\" && tox")),

        // MARK: Flutter / Dart

        .init(kind: .dartTool, projectType: .flutter, folder: ".dart_tool",
              rootMarkers: ["pubspec.yaml"], lockfiles: ["pubspec.lock"],
              rebuildMarkers: ["pubspec.yaml"],
              reinstall: .command("cd \"{root}\" && flutter pub get")),
        .init(kind: .flutterBuild, projectType: .flutter, folder: "build",
              rootMarkers: ["pubspec.yaml"], lockfiles: ["pubspec.lock"],
              rebuildMarkers: ["pubspec.yaml"],
              reinstall: .command("cd \"{root}\" && flutter pub get")),

        // MARK: Android

        .init(kind: .dotGradle, projectType: .androidGradle, folder: ".gradle",
              rootMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle",
                            "settings.gradle.kts", "android/build.gradle", "android/build.gradle.kts"],
              rebuildMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle",
                               "settings.gradle.kts", "android/build.gradle", "android/build.gradle.kts"],
              reinstall: .guidance("Run your usual project build so Android or Java tools fetch what they need again.")),

        // MARK: Xcode / CocoaPods

        .init(kind: .pods, projectType: .xcode, folder: "Pods",
              rootMarkers: ["Podfile"], lockfiles: ["Podfile.lock"],
              reinstall: .cocoaPods),
        .init(kind: .pods, projectType: .xcode, folder: "ios/Pods",
              rootMarkers: ["ios/Podfile"], lockfiles: ["Podfile.lock"],
              reinstall: .cocoaPods),
        .init(kind: .swiftPMBuild, projectType: .swiftPackage, folder: ".build",
              rootMarkers: ["Package.swift"], rebuildMarkers: ["Package.swift"],
              reinstall: .command("cd \"{root}\" && swift build")),

        // MARK: Elixir / Erlang

        .init(kind: .elixirBuild, projectType: .elixir, folder: "_build",
              rootMarkers: ["mix.exs"], rebuildMarkers: ["mix.exs"],
              reinstall: .command("cd \"{root}\" && mix compile")),
        .init(kind: .elixirDeps, projectType: .elixir, folder: "deps",
              rootMarkers: ["mix.exs"], lockfiles: ["mix.lock"], rebuildMarkers: ["mix.exs"],
              reinstall: .command("cd \"{root}\" && mix deps.get")),

        // MARK: JVM

        .init(kind: .mavenTarget, projectType: .maven, folder: "target",
              rootMarkers: ["pom.xml"], rebuildMarkers: ["pom.xml"],
              reinstall: .command("cd \"{root}\" && mvn package")),
        .init(kind: .gradleBuild, projectType: .gradleJVM, folder: "build",
              rootMarkers: ["build.gradle", "build.gradle.kts"],
              rebuildMarkers: ["build.gradle", "build.gradle.kts"],
              reinstall: .command("cd \"{root}\" && ./gradlew build")),
        .init(kind: .sbtTarget, projectType: .sbt, folder: "target",
              rootMarkers: ["build.sbt"], rebuildMarkers: ["build.sbt"],
              reinstall: .command("cd \"{root}\" && sbt compile")),
        .init(kind: .sbtTarget, projectType: .sbt, folder: "project/target",
              rootMarkers: ["build.sbt"], rebuildMarkers: ["../build.sbt"],
              reinstall: .command("cd \"{root}\" && sbt compile")),

        // MARK: .NET

        .init(kind: .dotnetBin, projectType: .dotnet, folder: "bin",
              rootMarkers: [], rootMarkerExtensions: ["csproj", "fsproj", "vbproj", "sln"], rebuildMarkers: [],
              reinstall: .command("cd \"{root}\" && dotnet build")),
        .init(kind: .dotnetObj, projectType: .dotnet, folder: "obj",
              rootMarkers: [], rootMarkerExtensions: ["csproj", "fsproj", "vbproj", "sln"], rebuildMarkers: [],
              reinstall: .command("cd \"{root}\" && dotnet build")),

        // MARK: PHP / Ruby

        .init(kind: .composerVendor, projectType: .composer, folder: "vendor",
              rootMarkers: ["composer.json"], lockfiles: ["composer.lock"],
              rebuildMarkers: ["composer.json"],
              reinstall: .command("cd \"{root}\" && composer install")),
        .init(kind: .bundlerVendor, projectType: .bundler, folder: "vendor/bundle",
              rootMarkers: ["Gemfile"], lockfiles: ["../Gemfile.lock"],
              rebuildMarkers: ["../Gemfile"],
              reinstall: .command("cd \"{root}\" && bundle install")),

        // MARK: Haskell

        .init(kind: .stackWork, projectType: .haskellStack, folder: ".stack-work",
              rootMarkers: ["stack.yaml"], rebuildMarkers: ["stack.yaml"],
              reinstall: .command("cd \"{root}\" && stack build")),
        .init(kind: .cabalDist, projectType: .haskellCabal, folder: "dist-newstyle",
              rootMarkers: [], rootMarkerExtensions: ["cabal"], rebuildMarkers: [],
              reinstall: .command("cd \"{root}\" && cabal build")),

        // MARK: Zig / OCaml / native

        .init(kind: .zigCache, projectType: .zig, folder: ".zig-cache",
              rootMarkers: ["build.zig"], rebuildMarkers: ["build.zig"],
              reinstall: .command("cd \"{root}\" && zig build")),
        .init(kind: .zigCache, projectType: .zig, folder: "zig-cache",
              rootMarkers: ["build.zig"], rebuildMarkers: ["build.zig"],
              reinstall: .command("cd \"{root}\" && zig build")),
        .init(kind: .zigOut, projectType: .zig, folder: "zig-out",
              rootMarkers: ["build.zig"], rebuildMarkers: ["build.zig"],
              reinstall: .command("cd \"{root}\" && zig build")),
        .init(kind: .duneBuild, projectType: .ocamlDune, folder: "_build",
              rootMarkers: ["dune-project"], rebuildMarkers: ["dune-project"],
              reinstall: .command("cd \"{root}\" && dune build")),
        .init(kind: .cmakeBuild, projectType: .cmake, folder: "build",
              rootMarkers: ["CMakeLists.txt"], rebuildMarkers: ["CMakeLists.txt"],
              reinstall: .guidance("Re-run your usual CMake configure and build steps.")),

        // MARK: Infrastructure / engines

        // `.terraform` is mostly downloaded providers and modules, but it is also where
        // the backend writes `terraform.tfstate` and the selected workspace. Losing state
        // can mean losing track of real running infrastructure, so this is Check First,
        // and any folder actually holding state is refused outright rather than offered.
        .init(kind: .terraformPlugins, projectType: .terraform, folder: ".terraform",
              rootMarkers: [], rootMarkerExtensions: ["tf"], rebuildMarkers: [],
              refuseWhenPresent: ["terraform.tfstate", "terraform.tfstate.backup", "environment"],
              reinstall: .command("cd \"{root}\" && terraform init"),
              level: .medium),
        .init(kind: .godotCache, projectType: .godot, folder: ".godot",
              rootMarkers: ["project.godot"], rebuildMarkers: ["project.godot"],
              reinstall: .guidance("Rebuilt automatically the next time you open the project in Godot.")),

        // Unity and Unreal rebuild themselves, but a reimport or shader rebuild can
        // cost half an hour on a large project and starts the moment the editor next
        // opens. Deliberately `.medium` so they are never swept up by one-click or
        // scheduled cleaning; the user has to choose them.
        .init(kind: .unityLibrary, projectType: .unity, folder: "Library",
              rootMarkers: ["ProjectSettings/ProjectVersion.txt"],
              rebuildMarkers: ["ProjectSettings/ProjectVersion.txt"],
              reinstall: .guidance("Unity reimports the project the next time you open it. On a large project this can take a long time."),
              level: .medium),
        .init(kind: .unityTemp, projectType: .unity, folder: "Temp",
              rootMarkers: ["ProjectSettings/ProjectVersion.txt"],
              reinstall: .guidance("Recreated automatically the next time you open the project in Unity."),
              level: .medium),
        .init(kind: .unrealIntermediate, projectType: .unreal, folder: "Intermediate",
              rootMarkers: [], rootMarkerExtensions: ["uproject"], rebuildMarkers: [],
              reinstall: .guidance("Regenerated the next time you build the project in Unreal."),
              level: .medium),
        .init(kind: .unrealDerivedData, projectType: .unreal, folder: "DerivedDataCache",
              rootMarkers: [], rootMarkerExtensions: ["uproject"], rebuildMarkers: [],
              reinstall: .guidance("Unreal rebuilds this cache on the next build. Expect a long first build, including shader compilation."),
              level: .medium),
    ]

    // MARK: - Lookups

    private nonisolated static let rulesByType: [ProjectType: [ProjectArtifactRule]] =
        Dictionary(grouping: rules, by: \.projectType)

    private nonisolated static let rulesByKind: [DeletableArtifactKind: [ProjectArtifactRule]] =
        Dictionary(grouping: rules, by: \.kind)

    nonisolated static func rules(for type: ProjectType) -> [ProjectArtifactRule] {
        rulesByType[type] ?? []
    }

    nonisolated static func rules(forKind kind: DeletableArtifactKind) -> [ProjectArtifactRule] {
        rulesByKind[kind] ?? []
    }

    /// Rules grouped by the final component of their folder, so a path check only
    /// considers the handful of rules whose folder name could possibly match.
    nonisolated static let rulesByFolderName: [String: [ProjectArtifactRule]] =
        Dictionary(grouping: rules) { URL(fileURLWithPath: $0.folder).lastPathComponent }

    /// Folder names any rule can propose, used to skip descending into them while
    /// walking for project roots.
    nonisolated static let artifactFolderNames: Set<String> = Set(
        rules.map { URL(fileURLWithPath: $0.folder).lastPathComponent }
    )
}
