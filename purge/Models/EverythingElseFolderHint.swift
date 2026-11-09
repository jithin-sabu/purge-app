import Foundation

/// Where an app has its own way to free the space a folder holds, the steps and
/// a way to open it (#129, #157). Read only: every action here opens another app
/// or another tab, and none of them moves a file.
nonisolated struct EverythingElseFolderHint: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Opens the app that owns the folder.
        case openApp(bundleID: String, title: String)
        /// Opens a link the app handles, like Steam's uninstall page for a game.
        case openURL(URL, title: String)
        /// The folder is already listed on the Large Files tab, so the row links there.
        case showInLargeFiles
        /// The cleanable parts are on the Dev Tools tab, so the row links there.
        case showInDevTools
        /// The folder is a command-line tool the uninstaller lists (#225).
        case showInCommandLineTools
    }

    let steps: String
    let action: Action?

    static let steamBundleID = "com.valvesoftware.steam"

    /// The hint for a folder, or nil when Purge has nothing to add beyond Finder.
    /// `steamGames` is keyed by install folder, from the measurement.
    static func hint(
        for path: String,
        group: EverythingElseGroup,
        home: URL,
        steamGames: [String: SteamGame],
        commandLineTools: [String: String] = [:]
    ) -> EverythingElseFolderHint? {
        let homePath = OverviewSizedItem.normalized(home.path)
        let relative: String? = PathContainment.isInside(path, homePath) ? String(path.dropFirst(homePath.count + 1)) : nil

        if let name = commandLineTools[path] {
            return EverythingElseFolderHint(
                steps: String(localized: "\(name) is a command-line tool. The uninstaller lists it under Command-Line Tools with its commands, and can move them all to the Trash."),
                action: .showInCommandLineTools
            )
        }

        if let game = steamGames[path] {
            return EverythingElseFolderHint(
                steps: String(localized: "\(game.name) is installed by Steam. Steam asks first, then deletes the game's files permanently, not to the Trash. Only saves synced to Steam Cloud are kept."),
                action: URL(string: "steam://uninstall/\(game.appID)").map { .openURL($0, title: String(localized: "Uninstall in Steam")) }
            )
        }
        if path.hasSuffix("/steamapps/common") || path.contains("/steamapps/common/") {
            return EverythingElseFolderHint(
                steps: String(localized: "Steam keeps its installed games here. Uninstall a game from its page in your Steam library."),
                action: .openApp(bundleID: steamBundleID, title: String(localized: "Open Steam"))
            )
        }

        if let relative {
            if relative.hasPrefix("Library/Application Support/JetBrains/Toolbox") {
                return EverythingElseFolderHint(
                    steps: String(localized: "Toolbox keeps every version of each IDE it installed. Remove old versions in Toolbox under Settings."),
                    action: .openApp(bundleID: "com.jetbrains.toolbox", title: String(localized: "Open Toolbox"))
                )
            }
            if relative.hasPrefix("Library/Application Support/itch") {
                return EverythingElseFolderHint(
                    steps: String(localized: "itch installs games here. Uninstall one from its page in the itch app."),
                    action: .openApp(bundleID: "io.itch.app", title: String(localized: "Open itch"))
                )
            }
            if relative.hasPrefix("Library/Application Support/Steam") {
                return EverythingElseFolderHint(
                    steps: String(localized: "Steam's own data. The games are under Other Apps, where each can be uninstalled in Steam."),
                    action: .openApp(bundleID: steamBundleID, title: String(localized: "Open Steam"))
                )
            }
            if relative == "Library/Mail" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Mail keeps a copy of every message and attachment here. Mail > Settings > Accounts lets you download only recent attachments, and Mailbox > Erase Junk Mail and Erase Deleted Items free space."),
                    action: .openApp(bundleID: "com.apple.mail", title: String(localized: "Open Mail"))
                )
            }
            if relative == "Library/Messages" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Messages keeps the photos and videos from your conversations here. Messages > Settings > General > Keep messages sets how long they stay."),
                    action: .openApp(bundleID: "com.apple.MobileSMS", title: String(localized: "Open Messages"))
                )
            }
            if relative.hasPrefix("Pictures/Photos Library") {
                return EverythingElseFolderHint(
                    steps: String(localized: "Your Photos library. With iCloud Photos on, Photos > Settings > iCloud > Optimize Mac Storage keeps full-size originals in iCloud and smaller copies here."),
                    action: .openApp(bundleID: "com.apple.Photos", title: String(localized: "Open Photos"))
                )
            }
            if relative == "Movies/TV" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Films and shows downloaded in the TV app. Remove downloads from the Library in TV."),
                    action: .openApp(bundleID: "com.apple.TV", title: String(localized: "Open TV"))
                )
            }
            if relative == "Music/Music" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Your Music library and downloads. Remove downloads from the Library in Music."),
                    action: .openApp(bundleID: "com.apple.Music", title: String(localized: "Open Music"))
                )
            }
            if relative.hasPrefix("Movies/iMovie") {
                return EverythingElseFolderHint(
                    steps: String(localized: "iMovie keeps its libraries and rendered projects here. Delete old projects and events in iMovie."),
                    action: .openApp(bundleID: "com.apple.iMovieApp", title: String(localized: "Open iMovie"))
                )
            }
            if relative == "Music/GarageBand" {
                return EverythingElseFolderHint(
                    steps: String(localized: "GarageBand projects and the sounds it downloaded. Remove sound packs in GarageBand under Sound Library."),
                    action: .openApp(bundleID: "com.apple.garageband10", title: String(localized: "Open GarageBand"))
                )
            }
            if relative == ".docker" || relative == "Library/Containers/com.docker.docker" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Docker Desktop keeps its disk image here. It only shrinks from inside Docker: remove unused images and containers, or lower the disk image size under Settings > Resources."),
                    action: .openApp(bundleID: "com.docker.docker", title: String(localized: "Open Docker"))
                )
            }
            if relative == ".ollama" || relative == ".lmstudio" {
                return EverythingElseFolderHint(
                    steps: String(localized: "The models in here are listed one by one on the Large Files tab, where each can be removed."),
                    action: .showInLargeFiles
                )
            }
            if relative.hasPrefix("Library/Developer/") {
                return EverythingElseFolderHint(
                    steps: String(localized: "Xcode's caches, simulators and archives are on the Dev Tools tab."),
                    action: .showInDevTools
                )
            }
            // The disk spells these as the app did; compared without case.
            let folded = relative.lowercased()
            if folded == "library/application support/mobilesync" {
                return EverythingElseFolderHint(
                    steps: String(localized: "iPhone and iPad backups made on this Mac. Delete old ones in Finder: select the device, then Manage Backups. System Settings > General > Storage lists them too."),
                    action: nil
                )
            }
            if folded == "library/itunes" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Software updates downloaded for an iPhone or iPad. They are only needed while a device updates or restores."),
                    action: nil
                )
            }
            if folded == "library/mobile documents" {
                return EverythingElseFolderHint(
                    steps: String(localized: "The iCloud Drive files downloaded to this Mac. Large Files lists the big ones, and Keep Only in iCloud frees the space while the file stays in iCloud."),
                    action: .showInLargeFiles
                )
            }
            if folded == "library/cloudstorage" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Files a cloud service keeps on this Mac. In Finder, Control-click a file or folder and choose Remove Download to keep it online only."),
                    action: nil
                )
            }
            if folded == "library/containers/com.tencent.xinwechat" {
                return EverythingElseFolderHint(
                    steps: String(localized: "WeChat keeps your chat history and the photos, videos and files from your chats here. Its settings have a storage page under General that clears them chat by chat."),
                    action: .openApp(bundleID: "com.tencent.xinWeChat", title: String(localized: "Open WeChat"))
                )
            }
            if folded == "library/group containers/243lu875e5.groups.com.apple.podcasts" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Episodes the Podcasts app downloaded. Remove downloads in Podcasts, or have it remove played episodes in its settings."),
                    action: .openApp(bundleID: "com.apple.podcasts", title: String(localized: "Open Podcasts"))
                )
            }
        }

        // Folders outside the home folder, by their place on the startup disk.
        if isSameOrInside(path, anyOf: ["/opt/homebrew", "/usr/local/Cellar", "/usr/local/Caskroom", "/usr/local/Homebrew"]) {
            return EverythingElseFolderHint(
                steps: String(localized: "Homebrew keeps the tools and libraries it installed here. Running brew cleanup removes old versions, and the uninstaller lists each tool under Command-Line Tools."),
                action: nil
            )
        }
        if PathContainment.isInside(path, "/Library/Developer") {
            return EverythingElseFolderHint(
                steps: String(localized: "Xcode's Command Line Tools and simulator runtimes. The runtimes are listed on the Dev Tools tab."),
                action: .showInDevTools
            )
        }
        if isSameOrInside(path, anyOf: ["/Library/Audio", "/Library/Application Support/GarageBand", "/Library/Application Support/Logic"]) {
            return EverythingElseFolderHint(
                steps: String(localized: "Instruments, loops and audio plug-ins installed for every user. The sound library GarageBand and Logic Pro downloaded can be removed in System Settings > General > Storage > Music Creation."),
                action: nil
            )
        }

        switch group {
        case .otherUsers:
            if path == "/Users/Shared" {
                return EverythingElseFolderHint(
                    steps: String(localized: "Files every user on this Mac can see. Anything here is yours to tidy in Finder."),
                    action: nil
                )
            }
            return EverythingElseFolderHint(
                steps: String(localized: "Another user's home folder. Only that user, or an administrator in System Settings > Users & Groups, can remove it."),
                action: nil
            )
        case .chatApps:
            return EverythingElseFolderHint(
                steps: String(localized: "Chat history and the photos, videos and files from your conversations. Free the space from the app's own storage settings."),
                action: nil
            )
        case .cloudDrives:
            // The sync services' own data in Library is not a synced folder.
            guard relative?.hasPrefix("Library/") != true else { return nil }
            return EverythingElseFolderHint(
                steps: String(localized: "A folder a cloud service syncs. Removing a file here removes it from the service and from your other devices, so use the service's own online-only setting to free space."),
                action: nil
            )
        case .virtualMachines:
            return EverythingElseFolderHint(
                steps: String(localized: "A virtual machine or container disk. It only shrinks from inside the app that made it: delete the machines, images and snapshots you no longer need there."),
                action: nil
            )
        case .aiModels:
            return EverythingElseFolderHint(
                steps: String(localized: "The models in here are listed one by one on the Large Files tab, where each can be removed."),
                action: .showInLargeFiles
            )
        case .browsers:
            return EverythingElseFolderHint(
                steps: String(localized: "A browser's profile: bookmarks, history, extensions and the data sites store. Clear browsing data from the browser's own settings."),
                action: nil
            )
        case .otherApps, .mediaLibraries, .mailAndMessages, .deviceBackups, .protectedCaches,
             .developer, .systemTools, .systemAppData, .appData, .sharedAppData, .documents,
             .virtualMemory, .temporaryFiles, .trash, .macOS, .systemData:
            return nil
        }
    }

    private static func isSameOrInside(_ path: String, anyOf folders: [String]) -> Bool {
        folders.contains { PathContainment.isSameOrInside(path, $0) }
    }
}
