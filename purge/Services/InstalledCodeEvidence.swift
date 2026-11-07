import AppKit
import Foundation
import Security

/// What the code installed on this Mac claims as its own: bundle ids, signing
/// team ids, and app groups. The leftovers scan (issue #26) keeps anything that
/// installed code claims, so this is where "is the owner still here" gets its
/// facts.
///
/// A folder name alone cannot answer that question. A group container is named
/// after an app group, and the developer picks that name freely: OrbStack's app
/// is `dev.kdrag0n.MacVirt`, but its group is `HUAQ24HBR6.dev.orbstack`, so the
/// scan once offered the Docker data of an installed OrbStack (#197). Helpers,
/// extensions, XPC services, and updaters can also carry ids that share nothing
/// with their app's. So ownership is read from the code itself: every app in
/// the app roots and the code nested inside it, Apple's own apps, whatever is
/// running, and the programs launchd starts.
///
/// Every source only adds claims, so a source that misses something can only
/// leave a leftover unflagged, never flag one that is still in use.
nonisolated struct InstalledCodeEvidence {
    /// Lowercased bundle ids and signing identifiers of installed code, plus the
    /// labels and associated bundle ids of launchd jobs.
    var bundleIDs = Set<String>()
    /// Uppercased signing team ids of installed code.
    var teamIDs = Set<String>()
    /// Lowercased app-group ids from installed code's entitlements.
    var appGroups = Set<String>()
    /// Apps in the user's app roots whose signature was read, and those whose
    /// signature could not be read at all. Unsigned apps count as read: they
    /// have no team and no entitlements, which is a real answer.
    var userAppSignaturesRead = 0
    var userAppSignatureFailures = 0

    /// Whether team and entitlement claims can be trusted to be complete enough
    /// to call a group container orphaned. When most signatures fail to read
    /// (a Security framework failure, a future sandbox), the claim sets come back
    /// near empty, and judging groups by them would flag every group container
    /// whose name is not its app's bundle id, the #197 bug again. So below 90%
    /// read, group containers are not judged at all.
    var canJudgeAppGroups: Bool {
        let total = userAppSignaturesRead + userAppSignatureFailures
        guard userAppSignaturesRead > 0 else { return false }
        return userAppSignatureFailures * 10 <= total
    }

    mutating func add(_ signature: CodeSignature) {
        if let identifier = signature.identifier, !identifier.isEmpty {
            bundleIDs.insert(identifier.lowercased())
        }
        if let team = signature.teamID, !team.isEmpty {
            teamIDs.insert(team.uppercased())
        }
        for group in signature.appGroups where !group.isEmpty {
            appGroups.insert(group.lowercased())
        }
    }

    // MARK: Gathering

    /// An app NSWorkspace reports as running, reduced to what ownership needs.
    struct RunningApp {
        let bundleID: String?
        let bundleURL: URL?
    }

    static func currentRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL)
        }
    }

    /// Builds the evidence for the apps found in the user's app roots (already
    /// walked by the caller) plus every other source above. The sources are
    /// parameters so tests can pass fixtures instead of this Mac's state.
    static func gather(
        userAppBundles: [URL],
        systemAppRoots: [URL] = systemAppRoots,
        runningApps: [RunningApp]? = nil,
        launchdJobRoots: [URL] = launchdJobRoots()
    ) -> InstalledCodeEvidence {
        let systemApps = systemAppRoots.flatMap { AppBundleReach.appBundleURLs(in: $0) ?? [] }
        let running = runningApps ?? currentRunningApps()
        let jobs = launchdJobs(roots: launchdJobRoots)

        // Every bundle and program the merge below can look at, read side by
        // side first. The reads are independent, and one app at a time spent
        // most of the Leftovers scan waiting on them. The merge then runs in
        // the same order as before, so `visited` and the read counts come out
        // the same.
        var walked: [URL] = userAppBundles
        var unwalked: [URL] = systemApps
        var programs: [URL] = []
        for app in running {
            guard let url = app.bundleURL, !url.path.hasPrefix("/System/") else { continue }
            walked.append(url)
        }
        for job in jobs {
            guard let program = job.program else { continue }
            if let bundle = outermostCodeBundle(containing: program) {
                walked.append(bundle)
            } else {
                programs.append(program)
            }
        }
        walked = uniqued(walked)
        let walkedPaths = Set(walked.map(\.standardizedFileURL.path))
        unwalked = uniqued(unwalked).filter { !walkedPaths.contains($0.standardizedFileURL.path) }
        programs = uniqued(programs)

        // The nested code of every walked bundle, all walks side by side, then
        // every signature at once. Running the two in one pass nested one
        // parallel loop in another, which GCD runs one item at a time, so
        // Xcode's walk alone set the pace.
        let nested = nestedCodeBundleURLs(inEach: walked)
        var nestedByBundle: [String: [URL]] = [:]
        for (bundle, inside) in zip(walked, nested) {
            nestedByBundle[bundle.standardizedFileURL.path] = inside
        }
        let codeURLs = uniqued(walked + nested.flatMap { $0 } + unwalked)
        let codeReads = ConcurrentMap.values(codeURLs) { url in
            CodeRead(bundleID: bundleIdentifier(of: url), signature: CodeSignature.read(at: url))
        }
        let programReads = ConcurrentMap.values(programs) { CodeSignature.read(at: $0) }
        let codeByPath = Dictionary(
            zip(codeURLs.map(\.standardizedFileURL.path), codeReads),
            uniquingKeysWith: { first, _ in first }
        )
        let programByPath: [String: CodeSignature?] = Dictionary(
            zip(programs.map(\.standardizedFileURL.path), programReads),
            uniquingKeysWith: { first, _ in first }
        )
        let reads = Prefetched(nestedByBundle: nestedByBundle, codeByPath: codeByPath, programByPath: programByPath)

        var evidence = InstalledCodeEvidence()
        var visited = Set<String>()

        for app in userAppBundles {
            let readable = evidence.addBundle(app, includingNestedCode: true, visited: &visited, reads: reads)
            if readable {
                evidence.userAppSignaturesRead += 1
            } else {
                evidence.userAppSignatureFailures += 1
            }
        }

        // Apple's apps are not walked into the installed set (that would inflate
        // the completeness check), but their groups are real claims: Podcasts
        // owns `243LU875E5.groups.com.apple.podcasts`, a name that does not start
        // with `com.apple.`.
        for app in systemApps {
            evidence.addBundle(app, includingNestedCode: false, visited: &visited, reads: reads)
        }

        // An app can run from anywhere: a disk image, Downloads, another volume.
        for running in running {
            if let id = running.bundleID, !id.isEmpty {
                evidence.bundleIDs.insert(id.lowercased())
            }
            guard let url = running.bundleURL, !url.path.hasPrefix("/System/") else { continue }
            evidence.addBundle(url, includingNestedCode: true, visited: &visited, reads: reads)
        }

        // Updaters, agents, and privileged helpers often live outside the app
        // roots (Microsoft AutoUpdate in `/Library/Application Support`, helper
        // tools in `/Library/PrivilegedHelperTools`) and are only reachable
        // through the launchd job that starts them.
        for job in jobs {
            for id in job.bundleIDs where !id.isEmpty {
                evidence.bundleIDs.insert(id.lowercased())
            }
            guard let program = job.program else { continue }
            if let bundle = outermostCodeBundle(containing: program) {
                evidence.addBundle(bundle, includingNestedCode: true, visited: &visited, reads: reads)
            } else if visited.insert(program.standardizedFileURL.path).inserted,
                      let signature = reads.program(at: program) {
                evidence.add(signature)
            }
        }
        return evidence
    }

    /// One bundle's id and signature, read ahead of the merge in `gather`.
    private struct CodeRead {
        let bundleID: String?
        let signature: CodeSignature?
    }

    /// What `gather` read ahead, by standardized path. A path it did not read
    /// ahead is read when asked, so the merge never depends on the list above
    /// being complete.
    private struct Prefetched {
        let nestedByBundle: [String: [URL]]
        let codeByPath: [String: CodeRead]
        let programByPath: [String: CodeSignature?]

        func nested(in bundle: URL) -> [URL] {
            nestedByBundle[bundle.standardizedFileURL.path]
                ?? InstalledCodeEvidence.nestedCodeBundleURLs(in: bundle)
        }

        func code(at bundle: URL) -> CodeRead {
            codeByPath[bundle.standardizedFileURL.path]
                ?? CodeRead(
                    bundleID: InstalledCodeEvidence.bundleIdentifier(of: bundle),
                    signature: CodeSignature.read(at: bundle)
                )
        }

        func program(at url: URL) -> CodeSignature? {
            if let read = programByPath[url.standardizedFileURL.path] { return read }
            return CodeSignature.read(at: url)
        }
    }

    /// `urls` in order, each standardized path once.
    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Adds one bundle's claims and, when asked, those of the code nested inside
    /// it. Returns false when any of those signatures could not be read: an
    /// extension's groups are missing then, so the app counts toward the
    /// degraded-read threshold in `canJudgeAppGroups`.
    @discardableResult
    private mutating func addBundle(
        _ bundle: URL,
        includingNestedCode: Bool,
        visited: inout Set<String>,
        reads: Prefetched
    ) -> Bool {
        guard visited.insert(bundle.standardizedFileURL.path).inserted else { return true }
        var readable = addCode(reads.code(at: bundle))
        guard includingNestedCode else { return readable }
        for nested in reads.nested(in: bundle)
        where visited.insert(nested.standardizedFileURL.path).inserted {
            let nestedReadable = addCode(reads.code(at: nested))
            readable = readable && nestedReadable
        }
        return readable
    }

    @discardableResult
    private mutating func addCode(_ read: CodeRead) -> Bool {
        if let id = read.bundleID {
            bundleIDs.insert(id.lowercased())
        }
        guard let signature = read.signature else { return false }
        add(signature)
        return true
    }

    static let systemAppRoots: [URL] = [URL(fileURLWithPath: "/System/Applications", isDirectory: true)]

    // MARK: Nested code

    /// Folder extensions of code that can own its own container, group, or
    /// HTTP storage: helper apps, app extensions, XPC services, and system
    /// extensions.
    static let ownerCodeExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]

    /// Folders that never hold code that owns data, skipped so the walk stays
    /// cheap: localizations, compiled interface files, headers, and the
    /// dependency trees bundled by Electron and Python apps.
    static let skippedFolderExtensions: Set<String> = [
        "lproj", "nib", "storyboardc", "dsym", "momd", "xcassets", "scnassets", "car"
    ]
    static let skippedFolderNames: Set<String> = [
        "_CodeSignature", "Headers", "PrivateHeaders", "Modules", "node_modules",
        "__pycache__", "site-packages"
    ]

    /// How many folder entries one app's walk may look at. A guard against a
    /// runaway walk (Xcode's `Contents/Developer` alone holds hundreds of
    /// thousands), not a product limit. Breadth-first, so the shallow places
    /// helpers live (`PlugIns`, `XPCServices`, `Library/LoginItems`,
    /// `Frameworks/*/Versions/*/XPCServices`) are always reached first.
    static let nestedWalkEntryBudget = 20_000

    /// Every helper app, extension, XPC service, and system extension inside
    /// `bundle`, at any depth. Never follows a symlink.
    static func nestedCodeBundleURLs(in bundle: URL) -> [URL] {
        nestedCodeBundleURLs(inEach: [bundle])[0]
    }

    /// `nestedCodeBundleURLs(in:)` for each bundle, in order. The bundles are
    /// walked together: each round lists the next few queued folders of every
    /// unfinished bundle side by side, then counts each bundle's entries in its
    /// own queue order, so every bundle's budget runs out at the same entry as
    /// a walk that read one folder at a time.
    static func nestedCodeBundleURLs(inEach bundles: [URL]) -> [[URL]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let keySet = Set(keys)
        var walks = bundles.map { NestedWalk(queue: [$0], budget: nestedWalkEntryBudget) }

        while true {
            // Each folder carries its walk's budget at the start of the round.
            // A folder's entries past it can never be counted this round, so
            // they are not judged.
            var folders: [(walk: Int, folder: URL, budget: Int)] = []
            for (number, walk) in walks.enumerated() where walk.index < walk.queue.count && walk.budget > 0 {
                let end = min(walk.index + nestedWalkListingBatch, walk.queue.count)
                folders += walk.queue[walk.index..<end].map { (number, $0, walk.budget) }
            }
            guard !folders.isEmpty else { break }
            let listings = ConcurrentMap.values(folders) { item -> [NestedWalkEntry]? in
                guard let entries = try? fm.contentsOfDirectory(
                    at: item.folder,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { return nil }
                return entries.prefix(item.budget).map { entry in
                    let values = try? entry.resourceValues(forKeys: keySet)
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                        return NestedWalkEntry(url: entry, descends: false, isOwnerCode: false)
                    }
                    let name = entry.lastPathComponent
                    let ext = entry.pathExtension.lowercased()
                    guard !skippedFolderNames.contains(name), !skippedFolderExtensions.contains(ext) else {
                        return NestedWalkEntry(url: entry, descends: false, isOwnerCode: false)
                    }
                    return NestedWalkEntry(url: entry, descends: true, isOwnerCode: ownerCodeExtensions.contains(ext))
                }
            }
            for (item, listing) in zip(folders, listings) {
                walks[item.walk].take(listing)
            }
        }
        return walks.map(\.result)
    }

    /// One bundle's breadth-first walk in `nestedCodeBundleURLs(inEach:)`.
    private struct NestedWalk {
        var queue: [URL]
        var budget: Int
        var index = 0
        var result: [URL] = []

        /// Counts the listing of `queue[index]`, the next folder in order.
        /// A walk whose budget ran out ignores the rest of its round.
        mutating func take(_ listing: [NestedWalkEntry]?) {
            guard budget > 0 else { return }
            index += 1
            guard let entries = listing else { return }
            for entry in entries {
                budget -= 1
                if budget <= 0 { break }
                guard entry.descends else { continue }
                if entry.isOwnerCode {
                    result.append(entry.url)
                }
                queue.append(entry.url)
            }
        }
    }

    /// One folder entry as the nested-code walk judged it.
    private struct NestedWalkEntry {
        let url: URL
        /// A real folder (not a link) the walk goes into.
        let descends: Bool
        /// A helper app, extension, XPC service or system extension.
        let isOwnerCode: Bool
    }

    /// How many queued folders of each bundle one round of the nested-code walk
    /// lists. Small, so a walk that runs out of budget part way lists few
    /// folders it never uses.
    static let nestedWalkListingBatch = 128

    /// The bundle id from a bundle's `Info.plist`, in the macOS layout
    /// (`Contents/Info.plist`) or the iOS one (`Info.plist` at the root, as in
    /// an iPhone app's `Wrapper/<name>.app` on Apple silicon). Read directly
    /// rather than through `Bundle(url:)`, which caches per path for the life of
    /// the process.
    static func bundleIdentifier(of bundle: URL) -> String? {
        for relative in ["Contents/Info.plist", "Info.plist"] {
            let url = bundle.appendingPathComponent(relative)
            if let plist = NSDictionary(contentsOf: url) as? [String: Any],
               let id = plist["CFBundleIdentifier"] as? String,
               !id.isEmpty {
                return id
            }
        }
        return nil
    }

    // MARK: launchd jobs

    struct LaunchdJob {
        let bundleIDs: [String]
        let program: URL?
    }

    static func launchdJobRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
    }

    /// Every job plist in the launchd roots: its label, its associated bundle
    /// ids, and the program it starts when that program is on disk.
    static func launchdJobs(roots: [URL] = launchdJobRoots()) -> [LaunchdJob] {
        let fm = FileManager.default
        var jobs: [LaunchdJob] = []
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where entry.pathExtension == "plist" {
                guard let plist = NSDictionary(contentsOf: entry) as? [String: Any] else { continue }
                jobs.append(launchdJob(from: plist))
            }
        }
        return jobs
    }

    static func launchdJob(from plist: [String: Any]) -> LaunchdJob {
        var ids: [String] = []
        if let label = plist["Label"] as? String { ids.append(label) }
        if let associated = plist["AssociatedBundleIdentifiers"] as? String {
            ids.append(associated)
        } else if let associated = plist["AssociatedBundleIdentifiers"] as? [String] {
            ids.append(contentsOf: associated)
        }
        let path = (plist["Program"] as? String)
            ?? (plist["ProgramArguments"] as? [String])?.first
        var program: URL?
        if let path, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            program = URL(fileURLWithPath: path)
        }
        return LaunchdJob(bundleIDs: ids, program: program)
    }

    /// The outermost helper app, extension, or XPC service a program sits in,
    /// so an agent inside `Microsoft AutoUpdate.app` brings in the whole app.
    static func outermostCodeBundle(containing program: URL) -> URL? {
        var url = URL(fileURLWithPath: "/")
        for component in program.standardizedFileURL.pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if ownerCodeExtensions.contains(url.pathExtension.lowercased()) { return url }
        }
        return nil
    }
}

/// The app groups each installed app lists in its entitlements, its own and
/// those of the code nested in it, keyed by `InstalledApp.id`. The uninstaller
/// keeps a group container that an app the user is keeping lists here (#200).
/// The developer picks a group's name, so a group named after the app being
/// removed can still be one that another app shares.
///
/// Only an exact listing counts, never a shared signing team. The group named
/// after the app being removed is usually its own, and holding it back
/// whenever the developer has another app installed would leave most
/// uninstalls incomplete. A signature that cannot be read adds no claim, which
/// leaves that app judged by name, as before.
nonisolated struct AppGroupClaims: Equatable {
    /// Lowercased app groups, by app id. Apps that list none are left out.
    var groupsByAppID: [String: Set<String>] = [:]

    /// True when `app` or code inside it lists `group`.
    func app(_ app: InstalledApp, claims group: String) -> Bool {
        groupsByAppID[app.id]?.contains(group.lowercased()) == true
    }

    /// The claims of `apps`, read off the main actor.
    @concurrent static func gatherOffMain(
        for apps: [InstalledApp],
        leftovers: [UninstallItem]
    ) async -> AppGroupClaims {
        gather(for: apps, leftovers: leftovers)
    }

    /// The claims of `apps`. Empty when no leftover is a group container, the
    /// only category these claims apply to, so most uninstalls skip the reads:
    /// every app's signature and a walk of its nested code took 0.5 s for 28
    /// apps on a dev Mac, 0.17 s of it Xcode's walk.
    ///
    /// The apps Purge remembers from drives and added folders (#99) claim the
    /// groups they listed when their signature was last read, whether or not
    /// the bundle is there now. An app on a drive that is unplugged has no
    /// signature to read, and one whose added folder was removed from the list
    /// is no longer in `apps`, but both still use their group containers.
    /// `remembered` only ever adds claims.
    static func gather(
        for apps: [InstalledApp],
        leftovers: [UninstallItem],
        readSignature: (URL) -> CodeSignature? = CodeSignature.read(at:),
        remembered: [DriveAppMemory.Entry] = DriveAppMemory.presentEntries()
    ) -> AppGroupClaims {
        var claims = AppGroupClaims()
        guard leftovers.contains(where: { $0.category == .groupContainers }) else { return claims }
        for entry in remembered where !entry.appGroups.isEmpty {
            claims.groupsByAppID[entry.bundlePath, default: []].formUnion(entry.appGroups.map { $0.lowercased() })
        }
        for app in apps {
            let code = [app.bundleURL] + InstalledCodeEvidence.nestedCodeBundleURLs(in: app.bundleURL)
            let groups = Set(code.flatMap { readSignature($0)?.appGroups ?? [] }.map { $0.lowercased() })
            if !groups.isEmpty {
                claims.groupsByAppID[app.id, default: []].formUnion(groups)
            }
        }
        return claims
    }
}

/// The parts of a code signature that say who the code belongs to.
nonisolated struct CodeSignature: Equatable {
    var identifier: String?
    var teamID: String?
    var appGroups: [String] = []

    /// Entitlement keys that list app groups. Apple's own apps use the
    /// restricted key next to the public one.
    static let appGroupEntitlementKeys = [
        "com.apple.security.application-groups",
        "com.apple.private.security.restricted-application-groups"
    ]

    /// Reads the signature of a bundle or a bare executable without validating
    /// it: ownership is a claim to keep data, so a forged one can only keep more.
    /// Nil only when the signature cannot be read at all. Unsigned code reads as
    /// a signature with no identifier, team, or groups.
    static func read(at url: URL) -> CodeSignature? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        let status = SecCodeCopySigningInformation(staticCode, flags, &info)
        if status == errSecCSUnsigned { return CodeSignature() }
        guard status == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return CodeSignature(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            appGroups: appGroups(fromEntitlements: entitlements)
        )
    }

    static func appGroups(fromEntitlements entitlements: [String: Any]) -> [String] {
        appGroupEntitlementKeys.flatMap { key -> [String] in
            if let groups = entitlements[key] as? [String] { return groups }
            if let group = entitlements[key] as? String { return [group] }
            return []
        }
    }
}
