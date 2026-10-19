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
nonisolated enum EverythingElseGroup: String, CaseIterable, Sendable, Codable {
    /// Steam libraries, JetBrains Toolbox, Epic and itch installs.
    case otherApps
    /// The Photos, Photo Booth, Music, TV, iMovie and GarageBand libraries.
    case mediaLibraries
    /// Mail's and Messages' own folders.
    case mailAndMessages
    /// `~/Library/Caches` folders that are off the allowlist.
    case protectedCaches
    /// Project folders such as `~/Developer`, `~/Library/Developer`, and the
    /// hidden folders in the home folder that Dev Tools does not own.
    case developer
    /// Application Support, Containers, Group Containers and the rest of
    /// `~/Library`, minus what App Caches and the installed apps already counted.
    case appData
    /// Documents, Desktop, Downloads, Movies, Music and Pictures, and the other
    /// folders in the home folder.
    case documents
    /// Every other home under `/Users`, and `/Users/Shared`.
    case otherUsers
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
        case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
             .developer, .appData, .documents, .otherUsers:
            return true
        case .trash, .macOS, .systemData:
            return false
        }
    }

    /// What the user can do about the space, which is what the page sorts by.
    var bucket: EverythingElseBucket {
        switch self {
        case .otherApps, .mediaLibraries, .mailAndMessages, .trash:
            return .managedInApps
        case .developer, .documents:
            return .yourFiles
        case .protectedCaches, .appData:
            return .leftAlone
        case .macOS, .systemData, .otherUsers:
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
