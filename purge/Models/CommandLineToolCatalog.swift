import Foundation

/// Command-line tools whose install the shim rule cannot see (#225). The rule
/// pairs a shim in `~/.local/bin` with the top-level `~/.<tool>` folder it
/// points into; Claude Code and cursor-agent install under `~/.local/share`,
/// which the rule never offers, and opencode puts its folder on `PATH` with no
/// shim at all. Each entry names one exact install folder, the shims that may
/// go with it, and the settings folders that stay.
///
/// The list is `purge/Resources/command-line-tools.json` and nothing else. A
/// folder shared with something else, such as `~/.gemini` or `~/.config`, is
/// never an install folder: `parse` refuses it, and refuses any overlap with
/// the app dot-folder catalog.
nonisolated struct CommandLineToolCatalog: Equatable, Sendable {
    nonisolated struct Entry: Decodable, Equatable, Sendable {
        let name: String
        /// Home-relative, starting `~/.`. Removed whole.
        let folder: String
        /// Home-relative, each directly inside `~/.local/bin`. Removed only
        /// when the shim points into `folder`.
        let shims: [String]
        /// Home-relative settings folders and files that stay. Shown, never removed.
        let kept: [String]
    }

    private struct File: Decodable {
        let tools: [Entry]
    }

    nonisolated enum ValidationError: Error, Equatable {
        case emptyName
        case notAHiddenHomePath(String)
        case sharedFolder(String)
        case nested(parent: String, child: String)
        case duplicateFolder(String)
        case shimOutsideLocalBin(String)
        case keptInsideFolder(String)
        case overlapsAppCatalog(String)
    }

    static let resourceName = "command-line-tools"
    static let shared = load()
    static let empty = CommandLineToolCatalog(entries: [])

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// The shipped catalog. Missing or invalid, it reads as empty, and an empty
    /// catalog offers nothing.
    static func load(bundle: Bundle = .main) -> CommandLineToolCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return (try? parse(data)) ?? .empty
    }

    static func parse(_ data: Data, appCatalog: AppDotFolderCatalog = .shared) throws -> CommandLineToolCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        try validate(file.tools, appCatalog: appCatalog)
        return CommandLineToolCatalog(entries: file.tools)
    }

    /// Every folder is a plain `~/.` path that is not a shared folder, no
    /// folder is listed twice or sits inside another, shims sit directly in
    /// `~/.local/bin`, kept paths are outside the folder, and nothing touches a
    /// folder the app catalog names.
    static func validate(_ entries: [Entry], appCatalog: AppDotFolderCatalog) throws {
        var folders: [String] = []
        let appFolders = appCatalog.entries.flatMap(\.folders)
        for entry in entries {
            guard !entry.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.emptyName }
            guard isPlainHiddenHomePath(entry.folder) else { throw ValidationError.notAHiddenHomePath(entry.folder) }
            let relative = String(entry.folder.dropFirst(2))
            guard !CommandLineToolScanPolicy.sharedFolders.contains(relative) else {
                throw ValidationError.sharedFolder(entry.folder)
            }
            guard !folders.contains(entry.folder) else { throw ValidationError.duplicateFolder(entry.folder) }
            folders.append(entry.folder)
            for app in appFolders where app == entry.folder
                || app.hasPrefix(entry.folder + "/") || entry.folder.hasPrefix(app + "/") {
                throw ValidationError.overlapsAppCatalog(entry.folder)
            }
            for shim in entry.shims {
                let name = shim.dropFirst(CommandLineToolScanPolicy.shimFolder.count + 3)
                guard shim.hasPrefix("~/" + CommandLineToolScanPolicy.shimFolder + "/"),
                      !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                    throw ValidationError.shimOutsideLocalBin(shim)
                }
            }
            for kept in entry.kept {
                guard isPlainHiddenHomePath(kept) else { throw ValidationError.notAHiddenHomePath(kept) }
                guard kept != entry.folder, !kept.hasPrefix(entry.folder + "/"),
                      !entry.folder.hasPrefix(kept + "/") else {
                    throw ValidationError.keptInsideFolder(kept)
                }
            }
        }
        for parent in folders {
            for child in folders where child.hasPrefix(parent + "/") {
                throw ValidationError.nested(parent: parent, child: child)
            }
        }
    }

    private static func isPlainHiddenHomePath(_ path: String) -> Bool {
        guard path.hasPrefix("~/.") else { return false }
        let components = path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first, first.count > 1 else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The URL a catalog path names, inside `home`.
    func url(for path: String, home: URL) -> URL? {
        LeftoverOwnerLedger.url(forRelativePath: path, home: home)
    }
}
