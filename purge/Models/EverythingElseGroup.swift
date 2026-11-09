import Foundation

/// The groups "Everything else" on the Overview is sorted into (#159, #220). These
/// are read only: Purge measures them and shows where the space is, and nothing
/// here is ever offered for cleaning. Anything that later turns out to be a
/// cleanable cache goes through the allowlist audit, not through these screens.
///
/// `allCases` is the claim order. A byte goes to the first group whose folder
/// holds it, after the five Overview categories have taken theirs: a Steam game
/// counts under Other Apps, and App Data keeps only the rest of Steam's folder.
/// The three display-only groups come last and claim nothing.
///
/// The named groups come before the catch-all ones they were split out
/// of. Chat Apps, Cloud Drives and the rest take their folders first, and
/// Developer, App Data and Documents keep what is left, so a new group only
/// ever moves bytes out of a catch-all and never adds any. Most of their
/// folders are picked by name from a root another group walks; see
/// `EverythingElseFolderCatalog`.
nonisolated enum EverythingElseGroup: String, CaseIterable, Sendable, Codable {
    /// Steam libraries, JetBrains Toolbox, Epic and itch installs, Heroic's
    /// games, CrossOver and Whisky bottles, and Minecraft.
    case otherApps
    /// The Photos, Photo Booth, Music, TV, iMovie and GarageBand libraries,
    /// Final Cut, Logic and Lightroom libraries, Podcasts and Books downloads,
    /// and the sound libraries GarageBand and Logic install for every user.
    case mediaLibraries
    /// Mail's and Messages' own folders.
    case mailAndMessages
    /// WeChat, WhatsApp, Telegram, Slack and the other chat apps' data.
    case chatApps
    /// iPhone and iPad backups and the software updates downloaded for them.
    case deviceBackups
    /// iCloud Drive, and the folders Dropbox, Google Drive, OneDrive and Box
    /// keep on this Mac.
    case cloudDrives
    /// Docker, OrbStack, UTM, Parallels, VMware and the other virtual machine
    /// and container disks.
    case virtualMachines
    /// The folders Ollama, LM Studio, Hugging Face and other local AI tools
    /// keep their models in, minus the models Large Files already lists.
    case aiModels
    /// Safari's, Chrome's, Firefox's and the other browsers' profiles.
    case browsers
    /// `~/Library/Caches` folders that are off the allowlist.
    case protectedCaches
    /// Project folders such as `~/Developer`, `~/Library/Developer`, SDKs and
    /// editors' data in `~/Library`, and the hidden folders in the home folder
    /// that Dev Tools does not own.
    case developer
    /// Homebrew, `/usr/local`, `/opt` and `/Library/Developer`: tools installed
    /// for the whole Mac.
    case systemTools
    /// What macOS and its built-in apps keep in `~/Library`: Notes, Calendar,
    /// Spotlight's index and the `com.apple` containers.
    case systemAppData
    /// Application Support, Containers, Group Containers and the rest of
    /// `~/Library`, minus what App Caches and the installed apps already counted.
    case appData
    /// `/Library`: what apps keep for every user of this Mac.
    case sharedAppData
    /// Documents, Desktop, Downloads, Movies, Music and Pictures, and the other
    /// folders in the home folder.
    case documents
    /// Every other home under `/Users`, and `/Users/Shared`.
    case otherUsers
    /// The swap files and the sleep image in `/private/var/vm`.
    case virtualMemory
    /// This user's folder in `/private/var/folders`: temporary files and the
    /// caches macOS keeps per user.
    case temporaryFiles
    /// What is in the Trash, from `TrashStore`. Display only.
    case trash
    /// The system volume, the figure System Settings shows. Display only.
    case macOS
    /// What the walk never reached, so the page still adds up to the used figure.
    case systemData

    /// The groups the walk measures, in claim order.
    static var measured: [EverythingElseGroup] {
        allCases.filter(\.isMeasured)
    }

    var isMeasured: Bool {
        switch self {
        case .otherApps, .mediaLibraries, .mailAndMessages, .chatApps, .deviceBackups,
             .cloudDrives, .virtualMachines, .aiModels, .browsers, .protectedCaches,
             .developer, .systemTools, .systemAppData, .appData, .sharedAppData,
             .documents, .otherUsers, .virtualMemory, .temporaryFiles:
            return true
        case .trash, .macOS, .systemData:
            return false
        }
    }

    /// Whether this group takes its bytes before `other` does.
    func claimsBefore(_ other: EverythingElseGroup) -> Bool {
        guard let mine = Self.allCases.firstIndex(of: self),
              let theirs = Self.allCases.firstIndex(of: other)
        else { return false }
        return mine < theirs
    }

    /// What the user can do about the space, which is what the page sorts by.
    var bucket: EverythingElseBucket {
        switch self {
        case .otherApps, .mediaLibraries, .mailAndMessages, .chatApps, .deviceBackups,
             .virtualMachines, .browsers, .trash:
            return .managedInApps
        case .cloudDrives, .aiModels, .developer, .systemTools, .documents:
            return .yourFiles
        case .protectedCaches, .systemAppData, .appData, .sharedAppData:
            return .leftAlone
        case .otherUsers, .virtualMemory, .temporaryFiles, .macOS, .systemData:
            return .managedByMacOS
        }
    }
}

/// What the user can do about a group's space (#159). The page's colours and its
/// sections follow these, in this order: the space you can free first, the space
/// you can do nothing about last.
nonisolated enum EverythingElseBucket: String, CaseIterable, Sendable {
    /// Freed from inside the app that keeps it: Photos, Mail, Steam, Finder's Trash.
    case managedInApps
    /// The user's own files, theirs to keep or remove.
    case yourFiles
    /// Folders Purge does not consider safe to delete, which it leaves alone.
    case leftAlone
    /// Space macOS creates and frees itself.
    case managedByMacOS

    var groups: [EverythingElseGroup] {
        EverythingElseGroup.allCases.filter { $0.bucket == self }
    }
}
