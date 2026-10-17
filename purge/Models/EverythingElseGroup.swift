import Foundation

/// The groups "Everything else" on the Overview is sorted into (#220). These are
/// read only: Purge measures them and shows where the space is, and nothing here
/// is ever offered for cleaning. Anything that later turns out to be a cleanable
/// cache goes through the allowlist audit, not through these screens.
///
/// `allCases` is the claim order. A byte goes to the first group whose folder
/// holds it, after the five Overview categories have taken theirs: a Steam game
/// counts under Apps outside Applications, and App data keeps only the rest of
/// Steam's folder. The two display-only groups come last and claim nothing.
nonisolated enum EverythingElseGroup: String, CaseIterable, Sendable, Codable {
    /// Steam libraries, JetBrains Toolbox, Epic and itch installs.
    case appsOutsideApplications
    /// Mail, Messages, and the Photos, Music, TV and iMovie libraries Large Files skips.
    case managedLibraries
    /// `~/Library/Caches` folders that are off the allowlist.
    case uncleanableCaches
    /// Application Support, Containers and Group Containers, minus the caches
    /// App Caches already counted.
    case appData
    /// Documents, Desktop, Downloads, Movies, Music and Pictures as whole folders.
    case yourFiles
    /// Dot folders in the home folder that Dev Tools does not own.
    case hiddenToolFolders
    /// Every other home under `/Users`, and `/Users/Shared`.
    case otherUsers
    /// The system volume, the figure System Settings shows. Drill-in only.
    case macOS
    /// What the walk never reached, so the page still adds up to the used figure.
    case notMeasured

    /// The groups the walk measures, in claim order.
    static var measured: [EverythingElseGroup] {
        allCases.filter(\.isMeasured)
    }

    var isMeasured: Bool {
        switch self {
        case .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
             .yourFiles, .hiddenToolFolders, .otherUsers:
            return true
        case .macOS, .notMeasured:
            return false
        }
    }

    /// Only the drill-in shows macOS: the Overview bar is Purge's findings and the
    /// rest, and the system volume is not something Purge measured folder by folder.
    var isShownOnOverview: Bool {
        switch self {
        case .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
             .yourFiles, .hiddenToolFolders, .otherUsers, .notMeasured:
            return true
        case .macOS:
            return false
        }
    }
}
