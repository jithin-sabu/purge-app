import Darwin
import Foundation

/// Old tool versions kept next to the one in use (#324): Cursor's unfinished
/// agent-CLI installs, old Claude Code downloads, Android NDK versions, Android
/// system images no emulator uses, and Figma profiles Figma has migrated away
/// from.
///
/// Every row is Check First. These are installed tools and profiles, not data an
/// app rebuilds by itself, and whether one is unused depends on the disk at the
/// moment of the move. `isWhitelistedPath` proves only the shape, for `evaluate`.
/// `refusesDeletion` reads the disk again, from `isOfferedForCleanup`, which
/// `FileDeleter` asks before every move. Anything that can't be read keeps the
/// entry, and no entry is offered when a folder on its way down from home is a
/// link.
nonisolated enum OldToolVersionScanPolicy {

    nonisolated enum Kind: Equatable, Sendable {
        /// `<versions>/.tmp-*` in a Cursor agent-CLI versions folder, or the
        /// `cursor-agent-*.tar.gz` the Cursor app downloads next to its copy.
        case cursorInstallLeftover
        /// `~/.claude/downloads/claude-<version>-<platform>`.
        case claudeCodeDownload
        /// `~/Library/Android/sdk/ndk/<version>`.
        case androidNDK
        /// `~/Library/Android/sdk/system-images/<api>/<tag>/<abi>`.
        case androidSystemImage
        /// `~/Library/Application Support/Figma/DesktopProfile/v<number>`.
        case figmaProfile
    }

    // MARK: Rows

    static let cursorLeftoverLabel = "Cursor Agent Install Leftovers"
    static let claudeDownloadLabel = "Old Claude Code Downloads"
    /// One row per NDK version, labelled `Android NDK <version>`.
    static let ndkLabelPrefix = "Android NDK "
    static let systemImagesLabel = "Unused Android System Images"
    static let figmaProfilesLabel = "Old Figma Profiles"

    static let ndkExplanationKey = "android-ndk-version"

    /// The version in an NDK row's label, or nil for any other label.
    static func ndkVersion(inLabel label: String) -> String? {
        guard label.hasPrefix(ndkLabelPrefix) else { return nil }
        let version = String(label.dropFirst(ndkLabelPrefix.count))
        return isDottedVersion(version) ? version : nil
    }

    // MARK: Places, relative to home

    static let cursorVersionsRoots = [
        ".local/share/cursor-agent/versions",
        "\(DeletionSafetyPolicy.cursorAgentWorkerCLI)/.local/share/cursor-agent/versions"
    ]
    /// Where the Cursor app leaves its agent-CLI download.
    static let cursorDownloadFolder = DeletionSafetyPolicy.cursorAgentWorkerCLI
    static let claudeDownloads = ".claude/downloads"
    static let claudeVersions = ".local/share/claude/versions"
    static let claudeCommand = ".local/bin/claude"
    /// Android Studio's default SDK. A custom SDK elsewhere is not looked at.
    static let androidSDK = "Library/Android/sdk"
    /// Figma's stable channel only. Beta keeps its profiles in `DesktopBeta/Profile`.
    static let figmaProfiles = "Library/Application Support/Figma/DesktopProfile"
    /// Figma writes this into a profile once it has copied the older one into it.
    /// From then on it never reads an older profile (seen in Figma's `app.asar`).
    static let figmaMigratedMarker = "FigmaProfileMigrated"

    /// An unfinished install or download must be this old. One in progress is
    /// minutes old.
    static let minimumLeftoverAge: TimeInterval = 24 * 60 * 60

    // MARK: Shape

    /// What `path` is by its place and name alone. Nil for everything else,
    /// including the folders that hold these entries and anything inside one.
    static func kind(of path: String, home: String) -> Kind? {
        for root in cursorVersionsRoots {
            if let name = onlyChild(path, of: "\(home)/\(root)"),
               name.hasPrefix(".tmp-"), name.count > ".tmp-".count {
                return .cursorInstallLeftover
            }
        }
        if let name = onlyChild(path, of: "\(home)/\(cursorDownloadFolder)"), isCursorDownloadName(name) {
            return .cursorInstallLeftover
        }
        if let name = onlyChild(path, of: "\(home)/\(claudeDownloads)"), claudeDownloadVersion(name) != nil {
            return .claudeCodeDownload
        }
        if let name = onlyChild(path, of: "\(home)/\(androidSDK)/ndk"), isDottedVersion(name) {
            return .androidNDK
        }
        let images = "\(home)/\(androidSDK)/system-images"
        if PathContainment.isInside(path, images) {
            let parts = path.dropFirst(images.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) {
                return .androidSystemImage
            }
        }
        if let name = onlyChild(path, of: "\(home)/\(figmaProfiles)"), figmaProfileNumber(name) != nil {
            return .figmaProfile
        }
        return nil
    }

    static func isWhitelistedPath(_ path: String, home: String) -> Bool {
        kind(of: path, home: home) != nil
    }

    /// The confirm sheet's line under a system image. Every image folder is named
    /// for its CPU (`arm64-v8a`), so it shows `android-36/google_apis/arm64-v8a`.
    /// Nil for every other path, which shows its own name.
    static func deletionSubtitle(for url: URL, home: String = DeletionSafetyPolicy.cachedHomePath) -> String? {
        let path = url.standardizedFileURL.path
        guard kind(of: path, home: home) == .androidSystemImage else { return nil }
        return String(path.dropFirst("\(home)/\(androidSDK)/system-images/".count))
    }

    /// The name of `path` when it sits directly in `root`.
    static func onlyChild(_ path: String, of root: String) -> String? {
        guard PathContainment.isInside(path, root) else { return nil }
        let name = path.dropFirst(root.count + 1)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return String(name)
    }

    /// `cursor-agent-2026.09.15-d2fe57e-31383-1789734822453.tar.gz`.
    static func isCursorDownloadName(_ name: String) -> Bool {
        let prefix = "cursor-agent-", suffix = ".tar.gz"
        return name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count > prefix.count + suffix.count
    }

    /// `claude-2.1.44-darwin-arm64` → `2.1.44`. The platform is ASCII letters,
    /// digits, `-` and `_`.
    static func claudeDownloadVersion(_ name: String) -> String? {
        guard name.hasPrefix("claude-") else { return nil }
        let rest = name.dropFirst("claude-".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let version = String(rest[..<dash])
        let platform = rest[rest.index(after: dash)...]
        guard isDottedVersion(version), !platform.isEmpty,
              platform.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        return version
    }

    /// `v43` → 43.
    static func figmaProfileNumber(_ name: String) -> Int? {
        guard name.hasPrefix("v") else { return nil }
        let digits = name.dropFirst()
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// Digits and dots, starting and ending with a digit, with at least one dot:
    /// `27.0.12077973`, `2.1.302`.
    static func isDottedVersion(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last,
              first.isASCII, first.isNumber, last.isASCII, last.isNumber,
              name.contains("."), !name.contains("..") else { return false }
        return name.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    static func isLower(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedAscending
    }

    // MARK: Delete-time gate

    /// The disk facts the system-image gate reads. Tests pass their own.
    nonisolated struct AndroidContext: Sendable {
        var avdHomes: [String]
        var emulatorIsRunning: @Sendable () -> Bool

        static func current(home: String) -> AndroidContext {
            AndroidContext(avdHomes: defaultAVDHomes(home: home), emulatorIsRunning: { isEmulatorRunning() })
        }
    }

    /// True when `url` has one of these shapes and the disk no longer shows it
    /// unused. False for every other path, which other rules judge.
    static func refusesDeletion(
        _ url: URL,
        home: String = DeletionSafetyPolicy.cachedHomePath,
        now: Date = Date(),
        android: AndroidContext? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard let kind = kind(of: path, home: home) else { return false }
        return !isOffered(path, kind: kind, home: home, now: now, android: android ?? .current(home: home))
    }

    static func isOffered(_ path: String, kind: Kind, home: String, now: Date, android: AndroidContext) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !PathContainment.containsSymlinkComponent(url, home: home) else { return false }
        switch kind {
        case .cursorInstallLeftover:
            let wantsFolder = url.lastPathComponent.hasPrefix(".tmp-")
            guard wantsFolder ? isRealFolder(path) : isRegularFile(path) else { return false }
            return isUnchanged(path, before: now.addingTimeInterval(-minimumLeftoverAge))
        case .claudeCodeDownload:
            guard isRegularFile(path),
                  let version = claudeDownloadVersion(url.lastPathComponent),
                  let inUse = DeletionSafetyPolicy.cliVersionInUse(
                    versionsRoot: "\(home)/\(claudeVersions)",
                    command: "\(home)/\(claudeCommand)"
                  ),
                  isDottedVersion(inUse) else { return false }
            return isLower(version, than: inUse)
                && isUnchanged(path, before: now.addingTimeInterval(-minimumLeftoverAge))
        case .androidNDK:
            let root = url.deletingLastPathComponent().path
            guard isCompleteNDK(path), let newest = newestCompleteNDK(in: root) else { return false }
            return isLower(url.lastPathComponent, than: newest)
        case .androidSystemImage:
            guard isRealFolder(path), !android.emulatorIsRunning(),
                  let used = avdImageFolders(avdHomes: android.avdHomes, sdkRoot: "\(home)/\(androidSDK)") else {
                return false
            }
            return !used.contains(where: { PathContainment.isSameOrInside($0, path) || PathContainment.isSameOrInside(path, $0) })
        case .figmaProfile:
            guard isRealFolder(path), let number = figmaProfileNumber(url.lastPathComponent),
                  let current = currentFigmaProfile(in: url.deletingLastPathComponent().path) else { return false }
            return number < current
        }
    }

    // MARK: Disk reads

    static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The entry, and each entry directly in it when it is a folder, last changed
    /// before `cutoff`. False when any of them can't be read.
    static func isUnchanged(_ path: String, before cutoff: Date) -> Bool {
        func changedBefore(_ path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            return modified < cutoff
        }
        guard changedBefore(path) else { return false }
        guard isRealFolder(path) else { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.allSatisfy { changedBefore("\(path)/\($0)") }
    }

    /// A finished NDK install: a real folder with `source.properties` and no
    /// `.installer`, which the SDK manager keeps while an install is under way
    /// and leaves behind when one fails.
    static func isCompleteNDK(_ path: String) -> Bool {
        var info = stat()
        return isRealFolder(path)
            && isRegularFile("\(path)/source.properties")
            && lstat("\(path)/.installer", &info) != 0 && errno == ENOENT
    }

    /// The highest version among the finished installs in `ndkRoot`. It is kept,
    /// and so is any version above it, finished or not.
    static func newestCompleteNDK(in ndkRoot: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: ndkRoot) else { return nil }
        return names
            .filter { isDottedVersion($0) && isCompleteNDK("\(ndkRoot)/\($0)") }
            .max { isLower($0, than: $1) }
    }

    /// The number of the highest `vNN` folder, when Figma has finished moving
    /// into it. Nil when the highest has no marker yet, which is a migration
    /// under way or a profile Figma hasn't opened, or when nothing can be read.
    static func currentFigmaProfile(in profilesRoot: String) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profilesRoot) else { return nil }
        let numbered = names.compactMap { name in figmaProfileNumber(name).map { (name, $0) } }
        guard let highest = numbered.max(by: { $0.1 < $1.1 }) else { return nil }
        let folder = "\(profilesRoot)/\(highest.0)"
        guard isRealFolder(folder), isRegularFile("\(folder)/\(figmaMigratedMarker)") else { return nil }
        return highest.1
    }

    /// Where the emulator looks for AVDs: `~/.android/avd`, and the folders the
    /// Android variables name when Purge was started with them. A Mac app is
    /// usually started without the shell's variables, so an emulator set up
    /// elsewhere is seen only while it runs (`isEmulatorRunning`).
    static func defaultAVDHomes(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var homes = ["\(home)/.android/avd"]
        func add(_ key: String, _ suffix: String) {
            guard let value = environment[key], value.hasPrefix("/") else { return }
            homes.append(URL(fileURLWithPath: value + suffix).standardizedFileURL.path)
        }
        add("ANDROID_AVD_HOME", "")
        add("ANDROID_EMULATOR_HOME", "/avd")
        add("ANDROID_USER_HOME", "/avd")
        add("ANDROID_SDK_HOME", "/.android/avd")
        var seen = Set<String>()
        return homes.filter { seen.insert($0).inserted }
    }

    /// The system-image folders the AVDs name in `image.sysdir.N`, standardized.
    /// An AVD is every `*.avd` folder in an AVD home and the folder each `*.ini`
    /// there names in `path=` (or `path.rel=`). Nil, which keeps every image, when
    /// an AVD home exists and can't be listed, or an AVD's `config.ini` can't be
    /// read or names no image. A missing AVD home holds no AVDs.
    static func avdImageFolders(avdHomes: [String], sdkRoot: String) -> Set<String>? {
        let fileManager = FileManager.default
        var avds: Set<String> = []
        for avdHome in avdHomes {
            var info = stat()
            if lstat(avdHome, &info) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            guard let names = try? fileManager.contentsOfDirectory(atPath: avdHome) else { return nil }
            for name in names {
                if name.hasSuffix(".avd") {
                    avds.insert("\(avdHome)/\(name)")
                } else if name.hasSuffix(".ini") {
                    guard let text = try? String(contentsOfFile: "\(avdHome)/\(name)", encoding: .utf8) else {
                        return nil
                    }
                    let values = iniValues(text)
                    if let path = values["path"], path.hasPrefix("/") {
                        avds.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                    } else if let relative = values["path.rel"] {
                        // Relative to the emulator home, the folder that holds `avd`.
                        let base = URL(fileURLWithPath: avdHome).deletingLastPathComponent()
                        avds.insert(base.appendingPathComponent(relative).standardizedFileURL.path)
                    } else {
                        return nil
                    }
                }
            }
        }
        var images: Set<String> = []
        for avd in avds {
            var info = stat()
            // An `.ini` can outlive its AVD. With no folder there is nothing to start.
            if lstat(avd, &info) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            guard let text = try? String(contentsOfFile: "\(avd)/config.ini", encoding: .utf8) else { return nil }
            let folders = iniValues(text)
                .filter { $0.key.hasPrefix("image.sysdir.") && !$0.value.isEmpty }
                .map(\.value)
            guard !folders.isEmpty else { return nil }
            for folder in folders {
                let absolute = folder.hasPrefix("/") ? folder : "\(sdkRoot)/\(folder)"
                images.insert(URL(fileURLWithPath: absolute).standardizedFileURL.path)
            }
        }
        return images
    }

    /// `key=value` lines, spaces around both trimmed. Later lines win.
    static func iniValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            values[key] = value
        }
        return values
    }

    /// Whether an Android emulator runs: a process whose program is named
    /// `qemu-system-*` or `emulator`. True when the process list can't be read.
    static func isEmulatorRunning() -> Bool {
        guard let pids = ProcessWorkingDirectories.allProcessIDs() else { return true }
        return pids.contains { pid in
            guard let path = ProcessWorkingDirectories.executablePath(of: pid) else { return false }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.hasPrefix("qemu-system-") || name == "emulator"
        }
    }

    // MARK: Scan

    /// The Dev Tools rows, each listing only entries the gate offers now. Roots
    /// that a limited scan can't read without a prompt are skipped.
    static func definitions(
        home: URL,
        now: Date = Date(),
        android: AndroidContext? = nil
    ) -> [(label: String, paths: [URL])] {
        let homePath = home.standardizedFileURL.path
        let android = android ?? .current(home: homePath)

        func offered(in root: String, depth: Int = 1, includeHidden: Bool = false) -> [String] {
            guard ProtectedLocations.isReadable(URL(fileURLWithPath: root), access: .limited, home: home) else {
                return []
            }
            var found = [root]
            for _ in 0..<depth {
                found = found.flatMap { folder -> [String] in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                    return names.filter { includeHidden || !$0.hasPrefix(".") }.map { "\(folder)/\($0)" }
                }
            }
            return found.filter { path in
                guard let kind = kind(of: path, home: homePath) else { return false }
                return isOffered(path, kind: kind, home: homePath, now: now, android: android)
            }
            .sorted { isLower($0, than: $1) }
        }

        var rows: [(label: String, paths: [URL])] = []
        func add(_ label: String, _ paths: [String]) {
            if !paths.isEmpty { rows.append((label, paths.map { URL(fileURLWithPath: $0) })) }
        }

        let cursor = cursorVersionsRoots.flatMap { offered(in: "\(homePath)/\($0)", includeHidden: true) }
            + offered(in: "\(homePath)/\(cursorDownloadFolder)")
        add(cursorLeftoverLabel, cursor)
        add(claudeDownloadLabel, offered(in: "\(homePath)/\(claudeDownloads)"))
        for version in offered(in: "\(homePath)/\(androidSDK)/ndk") {
            add(ndkLabelPrefix + URL(fileURLWithPath: version).lastPathComponent, [version])
        }
        add(systemImagesLabel, offered(in: "\(homePath)/\(androidSDK)/system-images", depth: 3))
        add(figmaProfilesLabel, offered(in: "\(homePath)/\(figmaProfiles)"))
        return rows
    }
}
