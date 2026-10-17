import Foundation

/// The hidden folders app bundles write in the home folder, by bundle id (#224).
/// The Leftovers scan looks only in Library, so when Antigravity is removed its
/// 12.5 GB under `~/.gemini/antigravity*` stays. A dot folder's name says
/// nothing reliable about its owner, so these pairings come from a fixed list,
/// `purge/Resources/app-dot-folders.json`, and nowhere else.
///
/// Each entry names exact folders. A parent shared with other tools, such as
/// `~/.gemini`, which also holds the Gemini CLI's settings, is never listed and
/// never offered: `parse` refuses a catalog where one folder sits inside
/// another. Command-line tools are not in this list; they have no bundle to
/// check for and are the subject of #225.
nonisolated struct AppDotFolderCatalog: Equatable, Sendable {
    nonisolated struct Entry: Decodable, Equatable, Sendable {
        let bundleID: String
        let displayName: String
        /// Home-relative, each starting `~/.`.
        let folders: [String]

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case displayName = "display_name"
            case folders
        }
    }

    private struct File: Decodable {
        let apps: [Entry]
    }

    nonisolated enum ValidationError: Error, Equatable {
        case badBundleID(String)
        case appleBundleID(String)
        case notAHiddenHomeFolder(String)
        case sharedParent(parent: String, child: String)
        case duplicateFolder(String)
    }

    static let resourceName = "app-dot-folders"
    static let shared = load()
    static let empty = AppDotFolderCatalog(entries: [])

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// The shipped catalog. Missing or invalid, it reads as empty, and an empty
    /// catalog offers nothing.
    static func load(bundle: Bundle = .main) -> AppDotFolderCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return (try? parse(data)) ?? .empty
    }

    static func parse(_ data: Data) throws -> AppDotFolderCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        try validate(file.apps)
        return AppDotFolderCatalog(entries: file.apps)
    }

    /// Every folder is `~/.<hidden>` or deeper with plain components, bundle ids
    /// look like bundle ids and are not Apple's, no folder is listed twice, and
    /// no folder contains another.
    static func validate(_ entries: [Entry]) throws {
        var all: [String] = []
        for entry in entries {
            guard OrphanLeftoverScanPolicy.looksLikeBundleID(entry.bundleID) else {
                throw ValidationError.badBundleID(entry.bundleID)
            }
            guard !OrphanLeftoverScanPolicy.isAppleIdentifier(entry.bundleID.lowercased()) else {
                throw ValidationError.appleBundleID(entry.bundleID)
            }
            for folder in entry.folders {
                let components = folder.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
                guard folder.hasPrefix("~/."),
                      let first = components.first, first.count > 1,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw ValidationError.notAHiddenHomeFolder(folder)
                }
                guard !all.contains(folder) else { throw ValidationError.duplicateFolder(folder) }
                all.append(folder)
            }
        }
        for parent in all {
            for child in all where child.hasPrefix(parent + "/") {
                throw ValidationError.sharedParent(parent: parent, child: child)
            }
        }
    }

    /// The folder a catalog path names, inside `home`.
    func url(for folder: String, home: URL) -> URL? {
        LeftoverOwnerLedger.url(forRelativePath: folder, home: home)
    }

    /// The entry naming exactly this path, or nil. Nothing inside or above a
    /// listed folder matches.
    func entry(forFolderAt url: URL, home: URL) -> Entry? {
        let path = url.standardizedFileURL.path
        for entry in entries {
            for folder in entry.folders {
                if self.url(for: folder, home: home)?.standardizedFileURL.path == path { return entry }
            }
        }
        return nil
    }
}
