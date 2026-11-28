import Darwin
import Foundation

/// Old tool versions kept next to the one in use (#324): Cursor's unfinished
/// agent-CLI installs, old Claude Code downloads, Android NDK versions, Android
/// build-tools and SDK platform versions no project names (#467), Android
/// system images no emulator uses, Figma profiles Figma has migrated away
/// from, Node.js versions nvm (#400) or Vite+ (#398) keeps that nothing
/// uses, with the folders an unfinished Vite+ install leaves, Rust
/// toolchains rustup keeps that nothing uses (#406), Python versions uv
/// keeps next to its minor-version links that nothing uses (#405), and Python
/// versions pyenv keeps that nothing uses (#404).
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
        /// `~/Library/Android/sdk/build-tools/<version>` (#467), judged by `AndroidSDKVersionPolicy`.
        case androidBuildTools
        /// `~/Library/Android/sdk/platforms/android-<level>` (#467), judged by `AndroidSDKVersionPolicy`.
        case androidPlatform
        /// `~/Library/Android/sdk/system-images/<api>/<tag>/<abi>`.
        case androidSystemImage
        /// `~/Library/Application Support/Figma/DesktopProfile/v<number>`.
        case figmaProfile
        /// `~/.nvm/versions/node/v<version>` (#400), judged by `NvmNodeVersionPolicy`.
        case nvmNodeVersion
        /// `<Vite+ data>/js_runtime/node/<version>` (#398), judged by `VitePlusNodeVersionPolicy`.
        case vitePlusNodeVersion
        /// `<Vite+ data>/js_runtime/.tmp*` (#398), judged by `VitePlusNodeVersionPolicy`.
        case vitePlusInstallLeftover
        /// `~/.rustup/toolchains/<name>` (#406), judged by `RustupToolchainPolicy`.
        case rustupToolchain
        /// `~/.local/share/uv/python/cpython-<version>-…` (#405), judged by `UvPythonVersionPolicy`.
        case uvPythonVersion
        /// `~/.pyenv/versions/<X.Y.Z>` (#404), judged by `PyenvPythonVersionPolicy`.
        case pyenvPythonVersion
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
        switch AndroidSDKVersionPolicy.folder(of: path, home: home) {
        case .buildTools: return .androidBuildTools
        case .platform: return .androidPlatform
        case nil: break
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
        if let name = onlyChild(path, of: "\(home)/\(NvmNodeVersionPolicy.versionsRoot)"),
           NvmNodeVersionPolicy.versionNumber(ofFolderName: name) != nil {
            return .nvmNodeVersion
        }
        if RustupToolchainPolicy.isToolchainPath(path, home: home) {
            return .rustupToolchain
        }
        if UvPythonVersionPolicy.isVersionPath(path, home: home) {
            return .uvPythonVersion
        }
        if PyenvPythonVersionPolicy.isVersionPath(path, home: home) {
            return .pyenvPythonVersion
        }
        switch VitePlusNodeVersionPolicy.kind(of: path, home: home) {
        case .version: return .vitePlusNodeVersion
        case .installLeftover: return .vitePlusInstallLeftover
        case nil: return nil
        }
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

    /// The facts the Android gates read besides the SDK itself. Tests pass their own.
    nonisolated struct AndroidContext: Sendable {
        var avdHomes: [String]
        /// Folders `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` or `ANDROID_NDK` name,
        /// when Purge was started with them.
        var ndkEnvironmentPaths: [String] = []
        var emulatorIsRunning: @Sendable () -> Bool

        static func current(
            home: String,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> AndroidContext {
            AndroidContext(
                avdHomes: defaultAVDHomes(home: home, environment: environment),
                ndkEnvironmentPaths: ["ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK"]
                    .compactMap { environment[$0] }
                    .filter { $0.hasPrefix("/") },
                emulatorIsRunning: { isEmulatorRunning() }
            )
        }
    }

    /// True when `url` has one of these shapes and the disk no longer shows it
    /// unused. False for every other path, which other rules judge.
    static func refusesDeletion(
        _ url: URL,
        home: String = DeletionSafetyPolicy.cachedHomePath,
        now: Date = Date(),
        android: AndroidContext? = nil,
        nvm: NvmNodeVersionPolicy.Context? = nil,
        vitePlus: VitePlusNodeVersionPolicy.Context? = nil,
        rustup: RustupToolchainPolicy.Context? = nil,
        uv: UvPythonVersionPolicy.Context? = nil,
        pyenv: PyenvPythonVersionPolicy.Context? = nil,
        androidSDKVersions: AndroidSDKVersionPolicy.Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard let kind = kind(of: path, home: home) else { return false }
        return !isOffered(
            path, kind: kind, home: home, now: now,
            android: android ?? .current(home: home),
            nvm: nvm,
            vitePlus: vitePlus,
            rustup: rustup,
            uv: uv,
            pyenv: pyenv,
            androidSDKVersions: androidSDKVersions,
            nvmCheck: .quick
        )
    }

    /// `nvmCheck` says how far an nvm, Vite+ (#398), rustup (#406), uv (#405), pyenv (#404) or
    /// Android build-tools or platform (#467) entry is judged:
    /// `refusesDeletion` may run on the main thread, so it takes `.quick`, and
    /// `FileDeleter` runs the rest right before the move
    /// (`passesImmediateTrashBoundary` in each policy).
    static func isOffered(
        _ path: String,
        kind: Kind,
        home: String,
        now: Date,
        android: AndroidContext,
        nvm: NvmNodeVersionPolicy.Context? = nil,
        vitePlus: VitePlusNodeVersionPolicy.Context? = nil,
        rustup: RustupToolchainPolicy.Context? = nil,
        uv: UvPythonVersionPolicy.Context? = nil,
        pyenv: PyenvPythonVersionPolicy.Context? = nil,
        androidSDKVersions: AndroidSDKVersionPolicy.Context? = nil,
        nvmCheck: NvmNodeVersionPolicy.Check = .scan
    ) -> Bool {
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
            let version = url.lastPathComponent
            guard isCompleteSDKPackage(path), let newest = newestCompleteNDK(in: root),
                  let pinned = pinnedNDKVersions(
                    sdkRoot: "\(home)/\(androidSDK)",
                    environmentPaths: android.ndkEnvironmentPaths
                  ) else { return false }
            return isLower(version, than: newest) && !pinned.contains(version)
        case .androidBuildTools, .androidPlatform:
            // Built here, not before: it probes Full Disk Access, which most rows don't need.
            return AndroidSDKVersionPolicy.isOffered(
                path, home: home, context: androidSDKVersions ?? .current(home: home), check: nvmCheck
            )
        case .androidSystemImage:
            guard isRealFolder(path),
                  let used = avdImageFolders(avdHomes: android.avdHomes, sdkRoot: "\(home)/\(androidSDK)", home: home)
            else { return false }
            let spellings = comparableSpellings(of: path)
            let named = used.contains { image in
                spellings.contains { PathContainment.isSameOrInside(image, $0) || PathContainment.isSameOrInside($0, image) }
            }
            // Last, since it lists every process: only for an image no AVD names.
            return !named && !android.emulatorIsRunning()
        case .figmaProfile:
            guard isRealFolder(path), let number = figmaProfileNumber(url.lastPathComponent),
                  let current = currentFigmaProfile(in: url.deletingLastPathComponent().path) else { return false }
            return number < current
        case .nvmNodeVersion:
            // Built here, not before: it probes Full Disk Access, which no other row needs.
            return NvmNodeVersionPolicy.isOffered(path, home: home, context: nvm ?? .current(home: home), check: nvmCheck)
        case .vitePlusNodeVersion, .vitePlusInstallLeftover:
            return VitePlusNodeVersionPolicy.isOffered(
                path, home: home, now: now, context: vitePlus ?? .current(home: home), check: nvmCheck
            )
        case .rustupToolchain:
            return RustupToolchainPolicy.isOffered(
                path, home: home, now: now, context: rustup ?? .current(home: home), check: nvmCheck
            )
        case .uvPythonVersion:
            return UvPythonVersionPolicy.isOffered(
                path, home: home, now: now, context: uv ?? .current(home: home), check: nvmCheck
            )
        case .pyenvPythonVersion:
            return PyenvPythonVersionPolicy.isOffered(
                path, home: home, now: now, context: pyenv ?? .current(home: home), check: nvmCheck
            )
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

    /// A finished SDK package install, such as an NDK, build-tools or platform
    /// version: a real folder with `source.properties` and no `.installer`,
    /// which the SDK manager keeps while an install is under way and leaves
    /// behind when one fails.
    static func isCompleteSDKPackage(_ path: String) -> Bool {
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
            .filter { isDottedVersion($0) && isCompleteSDKPackage("\(ndkRoot)/\($0)") }
            .max { isLower($0, than: $1) }
    }

    /// The lowest profile Figma may still use: the highest `vNN` once Figma has
    /// moved into it, or the one Figma wrote to last when that is lower, as after
    /// a downgrade to a Figma that opens an older profile again. Only folders
    /// below it are offered. Nil when the highest has no marker yet, which is a
    /// migration under way or a profile Figma hasn't opened, or when a profile
    /// can't be read.
    static func currentFigmaProfile(in profilesRoot: String) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profilesRoot) else { return nil }
        let numbered = names.compactMap { name in figmaProfileNumber(name).map { (name, $0) } }
        guard let highest = numbered.max(by: { $0.1 < $1.1 }) else { return nil }
        let folder = "\(profilesRoot)/\(highest.0)"
        guard isRealFolder(folder), isRegularFile("\(folder)/\(figmaMigratedMarker)") else { return nil }
        var lastUsed: (number: Int, written: Date)?
        for (name, number) in numbered {
            guard let written = lastWrite(in: "\(profilesRoot)/\(name)") else { return nil }
            if lastUsed == nil || written > lastUsed!.written
                || (written == lastUsed!.written && number > lastUsed!.number) {
                lastUsed = (number, written)
            }
        }
        return min(highest.1, lastUsed?.number ?? highest.1)
    }

    /// When anything directly in `folder` last changed. Chromium writes `Local
    /// State`, `Preferences` and its journals each time the profile is open.
    /// The folder's own date is left out: Figma's migration deletes cache
    /// folders from old profiles, which changes it. Nil when it can't be read.
    static func lastWrite(in folder: String) -> Date? {
        guard isRealFolder(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        var newest = Date.distantPast
        for name in names {
            var info = stat()
            guard lstat("\(folder)/\(name)", &info) == 0 else { return nil }
            newest = max(newest, Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
        }
        return newest
    }

    /// NDK versions something outside Gradle's own download points at:
    /// `sdk/ndk-bundle` linking to one, or an Android NDK variable naming one. A
    /// build set up that way fails instead of downloading the NDK again. Nil when
    /// `ndk-bundle` is a link that can't be read.
    static func pinnedNDKVersions(sdkRoot: String, environmentPaths: [String]) -> Set<String>? {
        let ndkRoot = "\(sdkRoot)/ndk"
        var targets = environmentPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let bundle = "\(sdkRoot)/ndk-bundle"
        var info = stat()
        if lstat(bundle, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: bundle) else { return nil }
            targets.append(URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: sdkRoot, isDirectory: true))
                .standardizedFileURL.path)
        }
        var pinned: Set<String> = []
        for target in targets {
            for spelling in comparableSpellings(of: target) {
                let root = ndkRoot.lowercased()
                guard PathContainment.isInside(spelling, root),
                      let version = spelling.dropFirst(root.count + 1).split(separator: "/").first else { continue }
                pinned.insert(String(version))
            }
        }
        return pinned
    }

    /// A program's load commands sit at its start, well inside this many bytes.
    static let programHeaderBytes = 256 * 1024

    /// Whether a program directly in one of `folders` (relative ones are in
    /// home) holds one of `needles` in its first `programHeaderBytes`, or in
    /// the first `programHeaderBytes` of each slice of a universal program,
    /// where its load commands name the libraries it loads. Links are skipped:
    /// they are `isLinkedFromBinFolder`'s to judge. Nil when a folder or a
    /// program can't be read, or a universal header can't be read whole.
    /// rustup (#406) and uv (#405) use it.
    static func programHeaders(
        in folders: [String], home: String, mayRead: (String) -> Bool, contain needles: [Data]
    ) -> Bool? {
        guard !needles.isEmpty else { return false }
        for relative in folders {
            let folder = relative.hasPrefix("/") ? relative : "\(home)/\(relative)"
            guard mayRead(folder) else { return nil }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                if NvmNodeVersionPolicy.isMissing(folder) { continue }
                return nil
            }
            for name in names {
                let program = "\(folder)/\(name)"
                var info = stat()
                // A folder that lists but can't be searched gives no answer.
                guard lstat(program, &info) == 0 else { return nil }
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                guard let handle = FileHandle(forReadingAtPath: program) else { return nil }
                defer { try? handle.close() }
                do {
                    // Nil at the end of the file, which an empty one reaches at once.
                    let header = try handle.read(upToCount: programHeaderBytes) ?? Data()
                    if needles.contains(where: { header.range(of: $0) != nil }) { return true }
                    // A universal program keeps each architecture's load
                    // commands at the start of its own slice, which may begin
                    // far past the first read.
                    switch fatSlices(in: header) {
                    case .notFat:
                        continue
                    case .malformed:
                        return nil
                    case .slices(let slices):
                        let fileSize = try handle.seekToEnd()
                        for slice in slices {
                            guard slice.offset <= fileSize, slice.size <= fileSize - slice.offset else { return nil }
                            try handle.seek(toOffset: slice.offset)
                            let start = try handle.read(upToCount: Int(min(slice.size, UInt64(programHeaderBytes)))) ?? Data()
                            if needles.contains(where: { start.range(of: $0) != nil }) { return true }
                        }
                    }
                } catch {
                    return nil
                }
            }
        }
        return false
    }

    /// What a program's first bytes say about its architecture slices.
    nonisolated enum FatHeader: Equatable {
        /// A single-architecture program, a script, or anything else.
        case notFat
        /// A universal program, with each slice's place in the file.
        case slices([FatSlice])
        /// A universal header Purge can't read whole.
        case malformed
    }

    nonisolated struct FatSlice: Equatable {
        var offset: UInt64
        var size: UInt64
    }

    /// The slices of a universal program, read from its header
    /// (`<mach-o/fat.h>`, big-endian). Java class files share the 32-bit magic;
    /// theirs is followed by a version of 45 or more, where a universal header
    /// counts its slices, which are never that many.
    static func fatSlices(in header: Data) -> FatHeader {
        func word(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= header.count else { return nil }
            let start = header.startIndex + at
            return header[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func doubleWord(_ at: Int) -> UInt64? {
            guard let high = word(at), let low = word(at + 4) else { return nil }
            return UInt64(high) << 32 | UInt64(low)
        }
        guard let magic = word(0), magic == 0xCAFE_BABE || magic == 0xCAFE_BABF,
              let count = word(4), count > 0, count < 45 else { return .notFat }
        let is64 = magic == 0xCAFE_BABF
        let entrySize = is64 ? 32 : 20
        var slices: [FatSlice] = []
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            if is64 {
                guard let offset = doubleWord(entry + 8), let size = doubleWord(entry + 16) else { return .malformed }
                slices.append(FatSlice(offset: offset, size: size))
            } else {
                guard let offset = word(entry + 8), let size = word(entry + 12) else { return .malformed }
                slices.append(FatSlice(offset: UInt64(offset), size: UInt64(size)))
            }
        }
        return .slices(slices)
    }

    /// Whether a process whose program is named one of `names` runs. True when
    /// the process list can't be read. rustup (#406) and uv (#405) use it.
    static func isProcessRunning(named names: Set<String>) -> Bool {
        guard let pids = ProcessWorkingDirectories.allProcessIDs() else { return true }
        return pids.contains { pid in
            guard let path = ProcessWorkingDirectories.executablePath(of: pid) else { return false }
            return names.contains(URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    /// `path` as written and with its links resolved, both in lowercase, since
    /// the Mac's disk ignores case. An in-use check matches either spelling.
    static func comparableSpellings(of path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return [url.path.lowercased(), url.resolvingSymlinksInPath().path.lowercased()]
    }

    /// Whether a path that an AVD setting names is missing. `false` when it is
    /// there. `true` when it is missing from the home folder, on the Mac's own
    /// disk, so it is gone. Nil when it is missing anywhere else, such as a drive
    /// under `/Volumes` that may only be unplugged, or can't be checked.
    static func isGone(_ path: String, home: String) -> Bool? {
        var info = stat()
        if lstat(path, &info) == 0 { return false }
        guard errno == ENOENT else { return nil }
        return PathContainment.isInside(path, home) ? true : nil
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
        // The older name for the folder that holds `.android`.
        add("ANDROID_PREFS_ROOT", "/.android/avd")
        var seen = Set<String>()
        return homes.filter { seen.insert($0).inserted }
    }

    /// The system-image folders the AVDs name in `image.sysdir.N`, in
    /// `comparableSpellings`. An AVD is every `*.avd` folder in an AVD home or one
    /// folder down (Gradle managed devices keep theirs in `gradle-managed`), and
    /// the folder each `*.ini` there names in `path=` (or `path.rel=`).
    ///
    /// Nil, which keeps every image, when an AVD home or an AVD is missing
    /// somewhere it may only be unplugged (`isGone`), when a folder can't be
    /// listed, when a folder sits deeper than Purge reads, or when an AVD's
    /// `config.ini` can't be read or names no image. An AVD home or AVD missing
    /// from the home folder holds nothing.
    static func avdImageFolders(avdHomes: [String], sdkRoot: String, home: String) -> Set<String>? {
        var avds: Set<String> = []

        /// Reads one folder of an AVD home. False when the answer can't be known.
        func collect(_ folder: String, avdHome: String, depth: Int) -> Bool {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
            for name in names {
                let entry = "\(folder)/\(name)"
                if name.hasSuffix(".avd") {
                    avds.insert(entry)
                } else if name.hasSuffix(".ini") {
                    guard let text = try? String(contentsOfFile: entry, encoding: .utf8) else { return false }
                    let values = iniValues(text)
                    if let path = values["path"], path.hasPrefix("/") {
                        avds.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                    } else if let relative = values["path.rel"] {
                        // Relative to the emulator home, the folder that holds `avd`.
                        let base = URL(fileURLWithPath: avdHome).deletingLastPathComponent()
                        avds.insert(base.appendingPathComponent(relative).standardizedFileURL.path)
                    } else {
                        return false
                    }
                } else {
                    var info = stat()
                    guard stat(entry, &info) == 0 else {
                        // A link that leads nowhere holds no AVD. Anything else unreadable might.
                        var linkInfo = stat()
                        if lstat(entry, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFLNK { continue }
                        return false
                    }
                    guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                    // One level down is read. A folder deeper than that is a layout Purge doesn't know.
                    guard depth == 0, collect(entry, avdHome: avdHome, depth: 1) else { return false }
                }
            }
            return true
        }

        for avdHome in avdHomes {
            guard let gone = isGone(avdHome, home: home) else { return nil }
            if gone { continue }
            guard collect(avdHome, avdHome: avdHome, depth: 0) else { return nil }
        }
        var images: Set<String> = []
        for avd in avds {
            // An `.ini` can outlive its AVD. With no folder there is nothing to start,
            // unless the folder is on a drive that is only unplugged.
            guard let gone = isGone(avd, home: home) else { return nil }
            if gone { continue }
            guard let text = try? String(contentsOfFile: "\(avd)/config.ini", encoding: .utf8) else { return nil }
            let folders = iniValues(text)
                .filter { $0.key.hasPrefix("image.sysdir.") && !$0.value.isEmpty }
                .map(\.value)
            guard !folders.isEmpty else { return nil }
            for folder in folders {
                let absolute = folder.hasPrefix("/") ? folder : "\(sdkRoot)/\(folder)"
                images.formUnion(comparableSpellings(of: absolute))
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
        android: AndroidContext? = nil,
        nvm: NvmNodeVersionPolicy.Context? = nil,
        vitePlus: VitePlusNodeVersionPolicy.Context? = nil,
        rustup: RustupToolchainPolicy.Context? = nil,
        uv: UvPythonVersionPolicy.Context? = nil,
        pyenv: PyenvPythonVersionPolicy.Context? = nil,
        androidSDKVersions: AndroidSDKVersionPolicy.Context? = nil
    ) -> [(label: String, paths: [URL])] {
        let homePath = home.standardizedFileURL.path
        let android = android ?? .current(home: homePath)
        let nvm = nvm ?? .current(home: homePath)
        let vitePlus = vitePlus ?? .current(home: homePath)
        let rustup = rustup ?? .current(home: homePath)
        let uv = uv ?? .current(home: homePath)
        let pyenv = pyenv ?? .current(home: homePath)
        let androidSDKVersions = androidSDKVersions ?? .current(home: homePath)

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
                return isOffered(
                    path, kind: kind, home: homePath, now: now,
                    android: android, nvm: nvm, vitePlus: vitePlus, rustup: rustup, uv: uv, pyenv: pyenv,
                    androidSDKVersions: androidSDKVersions
                )
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
        // One row per build-tools and platform version, like the NDK rows
        // (#467), from their own list so the Gradle files are read once.
        let sdkRoot = URL(fileURLWithPath: AndroidSDKVersionPolicy.sdkRoot(home: homePath))
        if ProtectedLocations.isReadable(sdkRoot, access: .limited, home: home) {
            let sdk = AndroidSDKVersionPolicy.offeredFolders(home: homePath, context: androidSDKVersions)
            for version in sdk.buildTools {
                add(AndroidSDKVersionPolicy.buildToolsLabelPrefix + URL(fileURLWithPath: version).lastPathComponent, [version])
            }
            for platform in sdk.platforms {
                let name = URL(fileURLWithPath: platform).lastPathComponent
                if let level = AndroidSDKVersionPolicy.platformLevel(ofFolderName: name) {
                    add(AndroidSDKVersionPolicy.platformLabelPrefix + String(level), [platform])
                }
            }
        }
        add(systemImagesLabel, offered(in: "\(homePath)/\(androidSDK)/system-images", depth: 3))
        add(figmaProfilesLabel, offered(in: "\(homePath)/\(figmaProfiles)"))
        // One row per version, like the NDK rows (#400).
        for version in offered(in: "\(homePath)/\(NvmNodeVersionPolicy.versionsRoot)") {
            let name = URL(fileURLWithPath: version).lastPathComponent
            if let number = NvmNodeVersionPolicy.versionNumber(ofFolderName: name) {
                add(NvmNodeVersionPolicy.labelPrefix + number, [version])
            }
        }
        // The same for Vite+, from both of its data folders (#398). A version in
        // both shares one row, and each folder passes the gate by itself.
        var vitePlusVersions: [String: [String]] = [:]
        var vitePlusLeftovers: [String] = []
        for root in VitePlusNodeVersionPolicy.dataRoots {
            for version in offered(in: "\(homePath)/\(root)/\(VitePlusNodeVersionPolicy.versionsFolder)") {
                vitePlusVersions[URL(fileURLWithPath: version).lastPathComponent, default: []].append(version)
            }
            vitePlusLeftovers += offered(
                in: "\(homePath)/\(root)/\(VitePlusNodeVersionPolicy.runtimeFolder)", includeHidden: true
            )
        }
        for name in vitePlusVersions.keys.sorted(by: { isLower($0, than: $1) }) {
            add(VitePlusNodeVersionPolicy.labelPrefix + name, vitePlusVersions[name] ?? [])
        }
        add(VitePlusNodeVersionPolicy.leftoversLabel, vitePlusLeftovers)
        // One row per rustup toolchain, labelled with its whole folder name
        // (#406). Its own list, so what keeps a toolchain is read once.
        let rustupRoot = URL(fileURLWithPath: "\(homePath)/\(RustupToolchainPolicy.toolchainsRoot)")
        if ProtectedLocations.isReadable(rustupRoot, access: .limited, home: home) {
            for toolchain in RustupToolchainPolicy.offeredFolders(home: homePath, now: now, context: rustup) {
                add(RustupToolchainPolicy.labelPrefix + URL(fileURLWithPath: toolchain).lastPathComponent, [toolchain])
            }
        }
        // One row per uv Python patch version no minor link points at, labelled
        // with its whole folder name (#405). Its own list, like rustup's.
        let uvRoot = URL(fileURLWithPath: "\(homePath)/\(UvPythonVersionPolicy.pythonRoot)")
        if ProtectedLocations.isReadable(uvRoot, access: .limited, home: home) {
            for version in UvPythonVersionPolicy.offeredFolders(home: homePath, now: now, context: uv) {
                add(UvPythonVersionPolicy.labelPrefix + URL(fileURLWithPath: version).lastPathComponent, [version])
            }
        }
        // One row per pyenv version (#404), from its own list like rustup's.
        let pyenvRoot = URL(fileURLWithPath: "\(homePath)/\(PyenvPythonVersionPolicy.versionsRoot)")
        if ProtectedLocations.isReadable(pyenvRoot, access: .limited, home: home) {
            for version in PyenvPythonVersionPolicy.offeredFolders(home: homePath, now: now, context: pyenv) {
                add(PyenvPythonVersionPolicy.labelPrefix + URL(fileURLWithPath: version).lastPathComponent, [version])
            }
        }
        return rows
    }
}
