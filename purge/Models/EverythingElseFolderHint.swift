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
        steamGames: [String: SteamGame]
    ) -> EverythingElseFolderHint? {
        let homePath = OverviewSizedItem.normalized(home.path)
        let relative: String? = path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : nil

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
        case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
             .developer, .appData, .documents, .trash, .macOS, .systemData:
            return nil
        }
    }
}
