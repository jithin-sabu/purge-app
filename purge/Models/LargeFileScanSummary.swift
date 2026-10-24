import Foundation

/// What a Large Files scan looked at and left off the list, so an empty result
/// can say why instead of reading as a scan that found nothing (#230).
///
/// Nothing here can be deleted: a cloud-only placeholder, a media library and a
/// folder the scan couldn't open are reported as counts and sizes only. The scan
/// still lists just the files that use space on this Mac.
nonisolated struct LargeFileScanSummary: Equatable, Sendable {
    /// Who holds a file that has a logical size but no bytes on this disk.
    enum CloudProvider: Hashable, Sendable {
        case iCloudDrive
        case oneDrive
        case dropbox
        case googleDrive
        case box
        /// A File Provider sync root Purge has no name for, by its folder prefix.
        case other(String)
        /// A placeholder outside any sync root Purge knows.
        case unknown

        var displayName: String {
            switch self {
            case .iCloudDrive: return "iCloud Drive"
            case .oneDrive: return "OneDrive"
            case .dropbox: return "Dropbox"
            case .googleDrive: return "Google Drive"
            case .box: return "Box"
            case .other(let name): return name
            case .unknown: return String(localized: "Cloud")
            }
        }

        /// Sort order for the bar and legend: named providers first, in a fixed
        /// order so the colours stay put between scans, the unknowns last.
        var sortRank: Int {
            switch self {
            case .iCloudDrive: return 0
            case .oneDrive: return 1
            case .dropbox: return 2
            case .googleDrive: return 3
            case .box: return 4
            case .other: return 5
            case .unknown: return 6
            }
        }

        /// Which provider a placeholder belongs to. The File Provider services keep
        /// theirs under `~/Library/CloudStorage/<Name>-…`, and a folder the user
        /// moved there (OneDrive's Folder Backup) resolves into it through a link,
        /// so the path is resolved first. The sync root wins over iCloud's item
        /// flag, which File Provider items can carry too; the flag decides only
        /// outside any sync root, where iCloud Drive keeps its files.
        static func provider(for url: URL, isUbiquitous: Bool, home: URL) -> CloudProvider {
            let cloudStorage = home
                .appendingPathComponent("Library/CloudStorage", isDirectory: true)
                .resolvingSymlinksInPath().path + "/"
            // The folder is resolved, not the file: a path whose last component is
            // missing resolves to itself, link and all.
            let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
            guard resolved.hasPrefix(cloudStorage) else { return isUbiquitous ? .iCloudDrive : .unknown }
            let folder = String(resolved.dropFirst(cloudStorage.count)).split(separator: "/").first.map(String.init) ?? ""
            let prefix = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
            switch prefix {
            case "OneDrive": return .oneDrive
            case "Dropbox": return .dropbox
            case "GoogleDrive": return .googleDrive
            case "Box": return .box
            case "": return .unknown
            default: return .other(prefix)
            }
        }
    }

    /// Files over the threshold that live only with one provider.
    struct CloudGroup: Equatable, Sendable, Identifiable {
        let provider: CloudProvider
        var count: Int
        /// Logical bytes: what the files would use if downloaded. None of it is on
        /// this disk.
        var bytes: Int64

        var id: String { provider.displayName }
    }

    /// A media library the walk stepped over. Its contents belong to the app that
    /// owns it, so Purge never lists them one by one.
    struct SkippedLibrary: Equatable, Sendable, Identifiable {
        let path: URL
        let bytes: Int64

        var id: String { path.path }
        /// "Photos Library" for `Photos Library.photoslibrary`.
        var name: String { path.deletingPathExtension().lastPathComponent }
        /// The app that opens this kind of library, for the row's button.
        var appName: String? {
            switch path.pathExtension.lowercased() {
            case "photoslibrary": return "Photos"
            case "imovielibrary", "theater": return "iMovie"
            case "tvlibrary": return "TV"
            case "musiclibrary": return "Music"
            default: return nil
            }
        }

        static let extensions: Set<String> = ["photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary", "theater"]
    }

    /// A scan root macOS refused to list. Looks exactly like an empty folder
    /// without this record.
    struct UnreadableRoot: Equatable, Sendable, Identifiable {
        let path: URL
        /// What macOS said, as a sentence, or empty when it gave no error.
        let reason: String

        var id: String { path.path }
        var name: String { LargeFileScanSummary.rootName(path) }
    }

    /// A root as Finder names it: iCloud Drive's own folder is called
    /// `com~apple~CloudDocs` on disk.
    static func rootName(_ root: URL) -> String {
        root.lastPathComponent == "com~apple~CloudDocs" ? String(localized: "iCloud Drive") : root.lastPathComponent
    }

    /// The size filter the scan ran with.
    let minBytes: Int64
    /// Roots that exist and were listed, in scan order.
    var checkedRoots: [URL] = []
    var unreadableRoots: [UnreadableRoot] = []
    var cloudOnly: [CloudGroup] = []
    var skippedLibraries: [SkippedLibrary] = []

    init(minBytes: Int64) {
        self.minBytes = minBytes
    }

    var cloudOnlyCount: Int { cloudOnly.reduce(0) { $0 + $1.count } }
    var cloudOnlyBytes: Int64 { cloudOnly.reduce(0) { $0 + $1.bytes } }
    var libraryBytes: Int64 { skippedLibraries.reduce(0) { $0 + $1.bytes } }

    /// Whether the summary has anything to show next to a list that has rows.
    var hasSkippedSomething: Bool {
        !cloudOnly.isEmpty || !skippedLibraries.isEmpty || !unreadableRoots.isEmpty
    }

    mutating func addCloudOnly(_ provider: CloudProvider, bytes: Int64) {
        if let index = cloudOnly.firstIndex(where: { $0.provider == provider }) {
            cloudOnly[index].count += 1
            cloudOnly[index].bytes += bytes
        } else {
            cloudOnly.append(CloudGroup(provider: provider, count: 1, bytes: bytes))
        }
        cloudOnly.sort { $0.provider.sortRank < $1.provider.sortRank }
    }
}

/// What a Large Files scan sends: its rows as it finds them, then one summary.
nonisolated enum LargeFileScanEvent: Sendable {
    case file(LargeFile)
    case finished(LargeFileScanSummary)
}
