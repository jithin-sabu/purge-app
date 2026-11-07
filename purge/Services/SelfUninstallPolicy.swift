import AppKit
import Foundation
import Security

/// The gate for Uninstall Purge (#330), the one place Purge moves its own files
/// to the Trash.
///
/// Two things may move, and nothing else. The running copy of Purge, and only
/// when it is a real, writable bundle that is this app: same bundle ID, and a
/// code signature that satisfies the running process's own designated
/// requirement. And, when the user ticks the box, Purge's own data folders, each
/// matched by exact path. Every refusal has a reason the sheet can show.
///
/// Both run again from disk right before the move. Clean Safe Items and
/// scheduled cleans never reach this; only `SelfUninstaller` calls it, after the
/// user confirmed the sheet.
nonisolated enum SelfUninstallPolicy {
    enum Refusal: Equatable, Sendable {
        /// Nothing at the path any more.
        case missing
        /// Not a `.app` folder, or a symbolic link to one.
        case notAnApp
        /// Another app, or a copy whose signature this process doesn't match.
        case notThisApp
        /// macOS runs a quarantined copy from a read-only mirror (App Translocation).
        case translocated
        /// A disk image or another volume that can't be written.
        case readOnlyVolume
        /// Already in a Trash, so there is nothing left to move.
        case alreadyInTrash
    }

    /// What `evaluateApp` needs to know about a bundle, read from disk by
    /// `readFacts(of:)` and built by hand in tests.
    struct BundleFacts: Equatable, Sendable {
        var path: String
        var exists: Bool
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var bundleIdentifier: String?
        var matchesRunningSignature: Bool
        var isOnReadOnlyVolume: Bool
    }

    static func evaluateApp(_ facts: BundleFacts, runningBundleIdentifier: String) -> Refusal? {
        guard facts.exists else { return .missing }
        guard facts.path.hasSuffix(".app"), facts.isDirectory, !facts.isSymbolicLink else { return .notAnApp }
        // Before the identity checks: a translocated copy is this app, but its
        // path is a temporary mirror, and moving it would not remove anything.
        if isTranslocated(path: facts.path) { return .translocated }
        if isInTrash(path: facts.path) { return .alreadyInTrash }
        guard !runningBundleIdentifier.isEmpty,
              facts.bundleIdentifier == runningBundleIdentifier,
              facts.matchesRunningSignature else { return .notThisApp }
        if facts.isOnReadOnlyVolume { return .readOnlyVolume }
        return nil
    }

    static func isTranslocated(path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// Under the user's `.Trash`, a volume's `.Trashes`, or iCloud Drive's `.Trash`.
    static func isInTrash(path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    // MARK: Data

    /// The released app's bundle ID, which names the Application Support folder.
    static let releasedBundleIdentifier = "io.getpurge.app"

    /// Purge's own folders, moved only when the user ticks the box. The caches
    /// and web storage folders are named after the running bundle. Application
    /// Support is the fixed folder every store uses (`AppSupportFolder`), so it
    /// is listed only for the released bundle ID: a dev build with an ID of its
    /// own shares that folder with the installed app and must not take it.
    static func dataFolders(home: URL, bundleIdentifier: String) -> [URL] {
        guard isValidBundleIdentifier(bundleIdentifier) else { return [] }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var folders: [URL] = []
        if bundleIdentifier == releasedBundleIdentifier {
            folders.append(library.appendingPathComponent("Application Support/\(releasedBundleIdentifier)", isDirectory: true))
        }
        folders.append(library.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true))
        folders.append(library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true))
        return folders
    }

    /// Reverse-DNS only: two or more dot-separated parts of letters, digits and
    /// hyphens. Rules out an empty ID, a slash, and `.` or `..`, any of which
    /// would point a folder name somewhere else.
    static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// True only for one of `dataFolders`, compared by exact standardized path,
    /// and only when it sits directly in its Library folder under the bundle's
    /// own name. A folder inside one, beside one, or a parent of one is refused.
    static func isOwnDataFolder(_ url: URL, home: URL, bundleIdentifier: String) -> Bool {
        guard isValidBundleIdentifier(bundleIdentifier) else { return false }
        let standardized = url.standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        let parent = standardized.deletingLastPathComponent().path
        let parents = ["Application Support", "Caches", "HTTPStorages"].map { "\(library)/\($0)" }
        let names = [bundleIdentifier, releasedBundleIdentifier]
        guard parents.contains(parent), names.contains(standardized.lastPathComponent) else { return false }
        return dataFolders(home: home, bundleIdentifier: bundleIdentifier)
            .contains { $0.standardizedFileURL.path == standardized.path }
    }

    /// The preferences file a copy of goes to the Trash. The domain itself is
    /// cleared through `UserDefaults`, because cfprefsd writes a deleted plist
    /// back about ten seconds later.
    static func preferencesFile(home: URL, bundleIdentifier: String) -> URL {
        home.appendingPathComponent("Library/Preferences/\(bundleIdentifier).plist")
    }

    /// Other copies of this app that Launch Services knows, still on disk and
    /// not in a Trash. They share Purge's settings and history.
    static func otherCopies(of running: URL, bundleIdentifier: String) -> [URL] {
        guard !bundleIdentifier.isEmpty else { return [] }
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        return otherCopies(among: known, running: running, exists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func otherCopies(among known: [URL], running: URL, exists: (URL) -> Bool) -> [URL] {
        let runningPath = running.resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>()
        return known.filter { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != runningPath, !isInTrash(path: path), seen.insert(path).inserted else { return false }
            return exists(url)
        }
    }

    // MARK: Moving the data

    enum DataItem: Equatable, Sendable {
        /// Moved itself, and moved back on a failure.
        case folder(URL)
        /// Copied first and the copy moved, so the original never leaves.
        case copyOf(URL)
    }

    /// Moves every item to the Trash or none. When one fails, the folders that
    /// already went are moved back to where they were; `.failedPartly` means
    /// at least one could not be. A copy left in the Trash is only a copy.
    static func moveAllOrNothing(
        _ items: [DataItem],
        trash: (URL) throws -> URL?,
        copy: (URL) throws -> URL,
        putBack: (URL, URL) throws -> Void
    ) -> SelfUninstallDataMove {
        var moved: [(original: URL, trashed: URL?)] = []
        for item in items {
            do {
                switch item {
                case .folder(let url):
                    moved.append((url, try trash(url)))
                case .copyOf(let url):
                    _ = try trash(try copy(url))
                }
            } catch {
                var allBack = true
                for entry in moved.reversed() {
                    guard let trashed = entry.trashed, (try? putBack(trashed, entry.original)) != nil else {
                        allBack = false
                        continue
                    }
                }
                return allBack ? .failed : .failedPartly
            }
        }
        return .moved
    }

    // MARK: Reading from disk

    static func readFacts(of url: URL) -> BundleFacts {
        let path = url.path
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let isLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return BundleFacts(
            path: path,
            exists: exists,
            isDirectory: isDirectory.boolValue,
            isSymbolicLink: isLink,
            bundleIdentifier: exists ? Bundle(url: url)?.bundleIdentifier : nil,
            matchesRunningSignature: exists && matchesRunningSignature(url),
            isOnReadOnlyVolume: values?.volumeIsReadOnly ?? false
        )
    }

    /// Whether the bundle on disk satisfies this process's designated
    /// requirement: the same team and identifier for a signed build, the same
    /// code for an ad hoc one.
    static func matchesRunningSignature(_ url: URL) -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return false }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var onDisk: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &onDisk) == errSecSuccess, let onDisk else { return false }
        return SecStaticCodeCheckValidity(onDisk, [], requirement) == errSecSuccess
    }

    /// Where the user's own copy is when macOS runs a translocated one. The
    /// lookup is in Security but not in its public headers, so it is found at
    /// run time; nil when it is missing or fails.
    static func originalURL(ofTranslocated url: URL) -> URL? {
        typealias Lookup = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        return lookup(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
