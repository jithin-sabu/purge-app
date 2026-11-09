import Foundation

/// A walked folder whose insides can belong to more than one group. The plan
/// stamps a root with the host it is, and the catalog below says which of the
/// folders directly inside it go to a named group instead of the root's own.
nonisolated enum EverythingElseHost: String, CaseIterable, Sendable {
    /// The home folder itself: its hidden folders and the rest of its visible ones.
    case home
    /// The rest of `~/Library`.
    case library
    case applicationSupport
    case containers
    case groupContainers
    case documents
    case movies
    case music
    case pictures
    /// The rest of `/Library`.
    case systemLibrary
    /// `/Library/Application Support`.
    case systemApplicationSupport
}

/// One line of the catalog: a folder directly inside a host, by name, and the
/// group that takes it. Names are compared lowercased, since the disk ignores
/// case by default.
nonisolated struct EverythingElseFolderRule: Equatable, Sendable {
    enum Match: Equatable, Sendable {
        case name(String)
        case prefix(String)
        case suffix(String)
    }

    let match: Match
    let group: EverythingElseGroup

    func matches(_ lowercasedName: String) -> Bool {
        switch match {
        case .name(let name): return lowercasedName == name
        case .prefix(let prefix): return lowercasedName.hasPrefix(prefix)
        case .suffix(let suffix): return lowercasedName.hasSuffix(suffix)
        }
    }
}

/// Which folders the named Everything else groups take out of the catch-all
/// ones: a chat app's container out of App Data, `~/Dropbox` out of Documents,
/// `~/.docker` out of Developer.
///
/// Read only, like everything on that page. A rule only says which group a
/// folder is shown under. It never makes a folder cleanable: nothing here
/// reaches the allowlist, `DeletionSafetyPolicy` or `FileDeleter`.
///
/// A folder is still counted once. The walk already sized it as a child of its
/// host, so a rule moves that one figure to another group and no folder is
/// walked twice. What an Overview category counted inside it is taken out
/// first, by the same `ClaimedPaths` every group goes through, so the named
/// groups hold only what the categories left.
///
/// A rule moves a folder only to a group that claims before its host's own
/// group (`group(forFolderAt:in:)` checks). That keeps the host's loose-file
/// claim, which covers the whole host, from swallowing a folder first.
nonisolated enum EverythingElseFolderCatalog {
    /// The rules for each host, first match wins. So a named folder comes
    /// before the prefix that would also match it: Safari's container before
    /// the `com.apple.` containers.
    static let rules: [EverythingElseHost: [EverythingElseFolderRule]] = [
        .containers: merged([
            names(.otherApps, ["com.isaacmarovitz.whisky"]),
            names(.mediaLibraries, ["com.apple.ibooksx", "com.apple.bkagentservice", "com.apple.podcasts"]),
            prefixes(.mailAndMessages, ["com.apple.mail", "com.apple.mobilesms", "com.apple.ichat"]),
            names(.chatApps, [
                "com.tencent.xinwechat", "com.tencent.qq", "com.tencent.weworkmac", "net.whatsapp.whatsapp",
                "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "jp.naver.line.mac", "ru.keepcoder.telegram"
            ]),
            names(.virtualMachines, ["com.docker.docker", "com.utmapp.utm"]),
            names(.aiModels, ["com.liuliu.draw-things"]),
            prefixes(.browsers, ["com.apple.safari"]),
            names(.browsers, ["com.duckduckgo.macos.browser"]),
            prefixes(.developer, ["com.apple.dt.", "com.apple.coresimulator"]),
            prefixes(.systemAppData, ["com.apple."])
        ]),
        .groupContainers: merged([
            names(.mediaLibraries, ["243lu875e5.groups.com.apple.podcasts", "group.com.apple.voicememos.shared"]),
            names(.mailAndMessages, ["group.com.apple.mail"]),
            names(.chatApps, ["group.net.whatsapp.whatsapp.shared"]),
            suffixes(.chatApps, [
                ".ru.keepcoder.telegram", ".com.microsoft.teams", ".jp.naver.line.mac", ".com.tencent.xinwechat"
            ]),
            suffixes(.deviceBackups, [".group.com.apple.configurator"]),
            names(.virtualMachines, ["group.com.docker"]),
            suffixes(.virtualMachines, [".dev.orbstack", ".com.parallels.desktop.appstore"]),
            prefixes(.systemAppData, ["group.com.apple.", "243lu875e5."])
        ]),
        .applicationSupport: merged([
            names(.otherApps, ["crossover", "minecraft", "heroic", "prismlauncher", "gog.com", "epic"]),
            names(.chatApps, [
                "signal", "slack", "discord", "telegram desktop", "whatsapp", "zoom.us", "dingtalkmac",
                "larkshell", "viberpc", "element"
            ]),
            names(.deviceBackups, ["mobilesync", "imazing"]),
            names(.cloudDrives, ["fileprovider", "clouddocs", "dropbox", "onedrive", "nextcloud"]),
            names(.virtualMachines, ["docker desktop", "rancher-desktop", "virtualbuddy"]),
            names(.aiModels, ["jan", "msty", "nomic.ai", "lm studio", "ollama"]),
            names(.browsers, [
                "microsoft edge", "bravesoftware", "arc", "firefox", "com.operasoftware.opera", "vivaldi",
                "chromium", "zen", "orion", "dia"
            ]),
            names(.developer, [
                "code", "code - insiders", "vscodium", "cursor", "windsurf", "zed", "jetbrains",
                "sublime text", "sublime text 3", "github desktop", "postman"
            ]),
            names(.systemAppData, [
                "addressbook", "callhistorydb", "callhistorytransactions", "knowledge", "facetime", "icloud",
                "crashreporter", "dock", "icdd", "networkserviceproxy", "syncservices"
            ]),
            prefixes(.systemAppData, ["com.apple."])
        ]),
        .library: merged([
            names(.deviceBackups, ["itunes"]),
            names(.cloudDrives, ["mobile documents", "cloudstorage"]),
            names(.virtualMachines, ["parallels"]),
            names(.browsers, ["safari"]),
            names(.developer, ["android", "java", "pnpm", "python", "unity", "r", "org.swift.swiftpm"]),
            names(.systemAppData, [
                "biome", "metadata", "suggestions", "assistant", "assistants", "trial", "daemon containers",
                "intelligenceplatform", "duetexpertcenter", "accounts", "calendars", "reminders", "photos",
                "passes", "keychains", "personalizationportrait", "homekit", "identityservices", "shortcuts",
                "sharing", "spelling", "stickers", "statuskit", "weather", "news", "finance", "translation",
                "languagemodeling", "keyboardservices", "corefollowup", "dataaccess", "datadeliveryservices",
                "unifiedassetframework", "dictionaries", "speech"
            ]),
            prefixes(.systemAppData, ["com.apple."])
        ]),
        .home: merged([
            names(.otherApps, ["games"]),
            names(.mediaLibraries, ["splice"]),
            names(.cloudDrives, [
                "dropbox", "google drive", "onedrive", "box", "box sync", "pcloud drive", "mega", "megasync",
                "nextcloud", "owncloud", "creative cloud files"
            ]),
            prefixes(.cloudDrives, ["icloud drive (archive)", "onedrive - ", "dropbox ("]),
            names(.virtualMachines, [
                "parallels", "virtual machines.localized", "virtual machines", "virtualbox vms",
                ".docker", ".orbstack", ".lima", ".colima", ".tart", ".vagrant.d", ".minikube", ".rd"
            ]),
            names(.aiModels, [
                ".ollama", ".lmstudio", ".diffusionbee", "pinokio", "stable-diffusion-webui", "comfyui"
            ]),
            names(.developer, [
                "go", "flutter", "miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba",
                "node_modules", "fvm"
            ])
        ]),
        .documents: merged([
            names(.mediaLibraries, ["native instruments"]),
            names(.virtualMachines, ["parallels", "virtual machines.localized"]),
            names(.aiModels, ["comfyui"]),
            names(.developer, ["github"])
        ]),
        .movies: merged([
            suffixes(.mediaLibraries, [".fcpbundle", ".imovielibrary", ".theater", ".tvlibrary"]),
            names(.mediaLibraries, ["final cut backups", "motion templates.localized"])
        ]),
        .music: merged([
            suffixes(.mediaLibraries, [".musiclibrary"]),
            names(.mediaLibraries, ["audio music apps", "logic", "ableton", "itunes"])
        ]),
        .pictures: merged([
            suffixes(.mediaLibraries, [".photoslibrary", ".lrlibrary", ".aplibrary", ".migratedphotolibrary"]),
            names(.mediaLibraries, ["lightroom", "capture one"])
        ]),
        .systemLibrary: merged([
            names(.mediaLibraries, ["audio"])
        ]),
        .systemApplicationSupport: merged([
            names(.mediaLibraries, ["garageband", "logic"])
        ])
    ]

    /// Folders a named group takes that sit deeper than one level inside a
    /// host, by home-relative path. Each is walked as a root of its own, the
    /// way the media libraries inside Pictures are: Chrome's profile is two
    /// levels into Application Support, under a `Google` folder that holds
    /// other things too.
    static let nestedFolders: [(group: EverythingElseGroup, relative: String)] = [
        (.chatApps, "Library/Application Support/Microsoft/Teams"),
        (.cloudDrives, "Library/Application Support/Google/DriveFS"),
        (.virtualMachines, ".local/share/containers"),
        (.virtualMachines, ".android/avd"),
        (.aiModels, ".cache/huggingface"),
        (.aiModels, ".cache/lm-studio"),
        (.aiModels, ".cache/torch"),
        (.aiModels, ".cache/whisper"),
        (.browsers, "Library/Application Support/Google/Chrome")
    ]

    /// The groups each host can hand a folder to.
    private static let adoptingGroups: [EverythingElseHost: Set<EverythingElseGroup>] =
        rules.mapValues { Set($0.map(\.group)) }

    /// The group a folder directly inside `root` is shown under: the catalog's
    /// when a rule names it, the root's own otherwise. A rule that would move
    /// the folder to a group claiming after the root's own is ignored.
    static func group(forFolderAt path: String, in root: EverythingElseMeasureRoot) -> EverythingElseGroup {
        guard let host = root.host, let hostRules = rules[host] else { return root.group }
        let name = (path as NSString).lastPathComponent.lowercased()
        guard let adopted = hostRules.first(where: { $0.matches(name) })?.group,
              adopted.claimsBefore(root.group)
        else { return root.group }
        return adopted
    }

    /// Whether a folder under `root` can end up in `group`: the root is the
    /// group's own, or the catalog moves some of its folders there. A group is
    /// measured once every root that feeds it is, and a limited scan left part
    /// of it unread when it skipped one of them.
    static func feeds(_ root: EverythingElseMeasureRoot, _ group: EverythingElseGroup) -> Bool {
        if root.group == group { return true }
        guard let host = root.host, adoptingGroups[host]?.contains(group) == true else { return false }
        return group.claimsBefore(root.group)
    }

    /// One host's rules in order. A list of lists, not a chain of `+`, which
    /// the type checker is slow to solve at this length.
    private static func merged(_ parts: [[EverythingElseFolderRule]]) -> [EverythingElseFolderRule] {
        parts.flatMap { $0 }
    }

    private static func names(_ group: EverythingElseGroup, _ names: [String]) -> [EverythingElseFolderRule] {
        names.map { EverythingElseFolderRule(match: .name($0), group: group) }
    }

    private static func prefixes(_ group: EverythingElseGroup, _ prefixes: [String]) -> [EverythingElseFolderRule] {
        prefixes.map { EverythingElseFolderRule(match: .prefix($0), group: group) }
    }

    private static func suffixes(_ group: EverythingElseGroup, _ suffixes: [String]) -> [EverythingElseFolderRule] {
        suffixes.map { EverythingElseFolderRule(match: .suffix($0), group: group) }
    }
}
