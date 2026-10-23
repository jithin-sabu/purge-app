import Foundation

/// Which installed apps Homebrew put there as casks (#254), read from the
/// Caskroom on disk. No `brew` process runs to find out.
///
/// When `brew install --cask` moves an app into place it leaves a link behind
/// in the Caskroom, `Caskroom/<token>/<version>/<App>.app -> /Applications/<App>.app`,
/// sometimes one folder down (`Media Converter.localized/Media Converter.app`).
/// That link is the only evidence this reads: an app is a cask's when a link
/// in that cask's folder points at the app's bundle. A cask with no such link,
/// such as a command-line binary or a cask whose app has been moved, matches
/// nothing.
///
/// Removal is Homebrew's: `PurgeStore` runs `brew uninstall --cask <token>`
/// through `PackageManagerUninstaller`, which deletes the app permanently.
/// The gate re-reads the link at delete time, and the token is a folder name
/// checked by `PackageManager.isValidPackageName` before it reaches argv.
nonisolated enum HomebrewCaskCatalog {
    static let defaultPrefixes: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
        URL(fileURLWithPath: "/usr/local", isDirectory: true)
    ]

    /// How deep below a version folder the app link may sit. One level covers
    /// a `.localized` or vendor folder around the app.
    static let linkDepth = 2

    /// Every cask whose app link resolves to a bundle on disk, keyed by that
    /// bundle's standardized path. A prefix with no `bin/brew` is skipped: with
    /// no program to run there is nothing Purge could do with the answer.
    static func installedCasks(prefixes: [URL] = defaultPrefixes) -> [String: HomebrewCask] {
        var result: [String: HomebrewCask] = [:]
        for prefix in prefixes {
            let brew = prefix.appendingPathComponent("bin/brew")
            guard FileManager.default.isExecutableFile(atPath: brew.path) else { continue }
            let caskroom = prefix.appendingPathComponent("Caskroom", isDirectory: true)
            for token in PackageManagerToolScanner.directoryNames(in: caskroom)
            where PackageManager.homebrewCask.isValidPackageName(token) {
                let cask = HomebrewCask(token: token, prefix: prefix)
                for bundlePath in appLinkTargets(inCask: caskroom.appendingPathComponent(token, isDirectory: true)) {
                    // The first cask to claim a bundle keeps it; two casks never
                    // install the same app, so this only guards a hand-made mess.
                    if result[bundlePath] == nil { result[bundlePath] = cask }
                }
            }
        }
        return result
    }

    /// The cask that owns `bundleURL`, re-read from disk now. Nil when none does.
    static func cask(owning bundleURL: URL, prefixes: [URL] = defaultPrefixes) -> HomebrewCask? {
        installedCasks(prefixes: prefixes)[bundleURL.standardizedFileURL.path]
    }

    /// The exact `brew uninstall --cask` run for `cask`, with the same fixed
    /// environment the formula uninstall uses. `bundleURL` is what the run must
    /// make disappear; `PackageManagerUninstaller` checks it before and after.
    static func uninstallTool(
        for cask: HomebrewCask,
        bundleURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PackageManagerTool {
        PackageManagerTool(
            manager: .homebrewCask,
            name: cask.token,
            locations: [bundleURL.standardizedFileURL],
            context: nil,
            executable: FileManager.default.isExecutableFile(atPath: cask.brewExecutable.path) ? cask.brewExecutable : nil,
            arguments: Array(PackageManager.homebrewCask.commandPrefix.dropFirst()) + [cask.token],
            environment: PackageManagerToolScanner.homebrewEnvironment(prefix: cask.prefix, home: home)
        )
    }

    /// The standardized paths of the `.app` bundles the links under one cask's
    /// version folders point at, when the bundle exists. Links are read, never
    /// followed into: a link to a folder that is not a bundle is ignored.
    static func appLinkTargets(inCask caskFolder: URL) -> [String] {
        var targets: [String] = []
        for version in PackageManagerToolScanner.directoryNames(in: caskFolder) {
            collectAppLinks(
                in: caskFolder.appendingPathComponent(version, isDirectory: true),
                depth: linkDepth,
                into: &targets
            )
        }
        return targets
    }

    private static func collectAppLinks(in folder: URL, depth: Int, into targets: inout [String]) {
        guard depth > 0 else { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            let entry = folder.appendingPathComponent(name)
            guard let type = (try? fm.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType else { continue }
            if type == .typeSymbolicLink {
                guard name.hasSuffix(".app"),
                      let destination = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
                let target = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : folder.appendingPathComponent(destination)
                let path = target.standardizedFileURL.path
                var isDirectory: ObjCBool = false
                guard path.hasSuffix(".app"),
                      fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                targets.append(path)
            } else if type == .typeDirectory, !name.hasSuffix(".app") {
                collectAppLinks(in: entry, depth: depth - 1, into: &targets)
            }
        }
    }
}
