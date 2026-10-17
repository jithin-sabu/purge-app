import AppKit
import Foundation

/// Rules for finding leftovers whose owning app is no longer installed (issue
/// #26). This is the uninstaller run in reverse: instead of "pick an app, what
/// does it own", it asks "what is here that no installed app owns". The whole
/// difficulty is false positives, so every rule here biases toward calling a
/// bundle id *owned* (and so leaving its data alone) rather than orphaned.
///
/// Kept separate from `AppUninstallScanPolicy` on purpose: that policy matches
/// leftovers to a chosen, still-installed app; this one decides absence. They
/// share the deletion gate (`isEligibleForUninstallDeletion`) and the
/// `UninstallItem`/`UninstallCategory` model, but nothing else.
enum OrphanLeftoverScanPolicy {

    // MARK: Roots

    /// A library root the orphan scan inspects, tagged with the category its
    /// direct children belong to. Every root here is one whose entries are keyed
    /// by a bundle identifier and are already accepted by
    /// `AppUninstallScanPolicy.isEligibleForUninstallDeletion`.
    ///
    /// `~/Library/Caches/<id>` is deliberately absent: the general cache scan
    /// already surfaces those folders (installed or not) as rebuildable caches,
    /// so listing them again here would double them up. Preferences and the two
    /// launch-item roots are also left out — they are tiny, noisy, and full of
    /// daemon/helper identifiers that never appear as apps, which is exactly
    /// where a wrong "orphaned" call is most likely.
    nonisolated struct OrphanRoot {
        let url: URL
        let category: UninstallCategory
    }

    nonisolated static func orphanRoots(home: URL) -> [OrphanRoot] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        return [
            OrphanRoot(
                url: lib.appendingPathComponent("Application Support", isDirectory: true),
                category: .applicationSupport
            ),
            OrphanRoot(
                url: lib.appendingPathComponent("Containers", isDirectory: true),
                category: .containers
            ),
            OrphanRoot(
                url: lib.appendingPathComponent("Group Containers", isDirectory: true),
                category: .groupContainers
            ),
            OrphanRoot(
                url: lib.appendingPathComponent("HTTPStorages", isDirectory: true),
                category: .caches
            ),
            OrphanRoot(
                url: lib.appendingPathComponent("Saved Application State", isDirectory: true),
                category: .savedState
            )
        ]
    }

    // MARK: Installed set

    /// The installed apps and what their code claims, used to decide whether a
    /// leftover's owner is still present. `owns` treats bundle ids as prefixes so
    /// a helper or extension id (`com.vendor.App.Helper`) is owned whenever its
    /// parent app (`com.vendor.App`) is installed.
    nonisolated struct InstalledAppIndex {
        /// Lowercased bundle ids of `.app` bundles found on disk in the user's app
        /// roots. Used both for ownership and for the completeness check.
        let diskBundleIDs: Set<String>

        /// Lowercased display names of those apps, as the uninstaller matches
        /// them (`AppUninstallScanner.displayName`). A human-named folder whose
        /// name is an installed app's name is that app's, whatever its id, so
        /// the human-name paths (#224) never attribute it to a removed app.
        var diskAppNames: Set<String> = []

        /// False when an app root existed on disk but could not be enumerated
        /// (a permissions failure, a volume going away mid-read). A degraded read
        /// undercounts installed apps, which would flag their leftovers as
        /// orphaned, so it suppresses the scan. Defaults to `true` so callers that
        /// build an index directly (tests) are unaffected.
        var rootsReadable: Bool = true

        /// Bundle ids, team ids, and app groups claimed by installed code beyond
        /// the app ids above (see `InstalledCodeEvidence`). Only ever adds
        /// claims. No default: without it, helper ids Launch Services cannot
        /// resolve (Sparkle's `org.sparkle-project.Downloader`) read as orphans,
        /// so every caller has to say what evidence it is judging with.
        var evidence: InstalledCodeEvidence

        var appCount: Int { diskBundleIDs.count }

        /// Guards against acting on a broken view of the world: an unmounted
        /// volume, an unreadable `/Applications`, or a sandbox with no Launch
        /// Services access all read as "almost nothing installed", which would
        /// flag every leftover as orphaned. The scan suppresses itself unless the
        /// roots read cleanly and there are at least a plausible number of apps.
        var looksComplete: Bool { rootsReadable && appCount >= minimumPlausibleAppCount }

        /// Whether an installed app owns this bundle id, by exact match or by
        /// being a parent of it. Biased toward owned: it tests the id and each
        /// parent prefix down to two components, and a hit anywhere means "keep".
        func owns(bundleID: String) -> Bool {
            let lower = bundleID.lowercased()
            var components = lower.split(separator: ".").map(String.init)
            while components.count >= 2 {
                let candidate = components.joined(separator: ".")
                if diskBundleIDs.contains(candidate) { return true }
                // Helpers, extensions, and XPC services inside installed apps,
                // whose ids need not share their app's prefix (Sparkle's
                // `org.sparkle-project.Downloader` ships inside many apps).
                if evidence.bundleIDs.contains(candidate) { return true }
                // LaunchServices resolves apps anywhere it has registered,
                // including `/System`, so this covers app roots the disk walk
                // does not. It returns nil for a pure helper/extension id, which
                // is why the prefix walk above is needed for those.
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil {
                    return true
                }
                components.removeLast()
            }
            return false
        }

        /// Whether installed code owns the `<team id>.<name>` app group
        /// `identifier`. The name after the team id is chosen freely by the
        /// developer and is not a bundle id (#197), so a name match is only one
        /// of three ways to claim it: the group is in an installed app's
        /// entitlements, or any installed code is signed by the same team, or
        /// the name is an installed bundle id. A vendor with any app still
        /// installed keeps all of its team-prefixed groups, which can hide a
        /// removed sibling's group but never offers a group a kept app uses.
        func owns(appGroup identifier: String, teamID: String) -> Bool {
            // Without readable signatures the claims below are near empty, and
            // judging by them would flag every group whose name is not its
            // app's bundle id.
            guard evidence.canJudgeAppGroups else { return true }
            if evidence.appGroups.contains(identifier.lowercased()) { return true }
            if evidence.teamIDs.contains(teamID.uppercased()) { return true }
            let name = String(identifier.dropFirst(teamID.count + 1))
            return OrphanLeftoverScanPolicy.looksLikeBundleID(name) && owns(bundleID: name)
        }
    }

    /// Fewer installed apps than this and the scan refuses to run — see
    /// `looksComplete`.
    nonisolated static let minimumPlausibleAppCount = 5

    /// Enumerates `.app` bundle identifiers in the user-facing app roots, as deep
    /// as the uninstaller looks (vendors group their apps, e.g.
    /// `/Applications/Utilities/…`), then gathers what all installed code claims.
    /// System apps are not counted: `owns` reaches them through LaunchServices
    /// and the evidence, and counting them would inflate `looksComplete` past the
    /// point where it can catch an empty world.
    nonisolated static func makeInstalledAppIndex() -> InstalledAppIndex {
        let fm = FileManager.default
        var ids = Set<String>()
        var names = Set<String>()
        var appBundles: [URL] = []
        // A root that is absent (e.g. no `~/Applications`) is fine and reads as
        // empty. A root that exists but fails to enumerate means our view of what
        // is installed is degraded, not just sparse, so the scan must not run.
        // A single unreadable subfolder is not treated as a degraded view: it
        // only hides vendor-grouped apps, and suppressing the whole scan for one
        // odd folder would be worse.
        var rootsReadable = true

        for root in AppUninstallScanPolicy.installedAppRoots() {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let bundles = AppBundleReach.appBundleURLs(in: root) else {
                rootsReadable = false
                continue
            }
            for url in bundles {
                appBundles.append(url)
                let bundle = Bundle(url: url)
                if let id = bundle?.bundleIdentifier, !id.isEmpty {
                    ids.insert(id.lowercased())
                }
                names.insert(AppUninstallScanner.displayName(for: url, bundle: bundle).lowercased())
            }
        }
        return InstalledAppIndex(
            diskBundleIDs: ids,
            diskAppNames: names,
            rootsReadable: rootsReadable,
            evidence: InstalledCodeEvidence.gather(userAppBundles: appBundles)
        )
    }

    // MARK: Owner keys

    /// What a leftover's name says about its owner. The two kinds are checked
    /// against different evidence and must never be mixed up: treating an app
    /// group's name as a bundle id is what flagged an installed OrbStack's data
    /// (#197).
    nonisolated enum LeftoverOwner: Equatable {
        /// An app, helper, or extension bundle id: Containers, HTTPStorages,
        /// Saved Application State, and Application Support entries.
        case bundleID(String)
        /// A `<team id>.<name>` app group: Group Containers entries. The whole
        /// folder name is the group identifier.
        case appGroup(String, teamID: String)

        /// The name shown on the row when Finder has no better one.
        var displayName: String {
            switch self {
            case .bundleID(let id):
                return id
            case .appGroup(let identifier, let teamID):
                return String(identifier.dropFirst(teamID.count + 1))
            }
        }
    }

    // MARK: Orphan test

    /// Whether a leftover keyed by `bundleID` should be treated as orphaned.
    nonisolated static func isOrphan(bundleID: String, installed: InstalledAppIndex) -> Bool {
        isOrphan(.bundleID(bundleID), installed: installed)
    }

    /// Whether a leftover with this owner should be treated as orphaned. Never
    /// true for Apple's own identifiers, protected containers, or Purge itself,
    /// and never true when installed code claims the owner.
    nonisolated static func isOrphan(_ owner: LeftoverOwner, installed: InstalledAppIndex) -> Bool {
        let name: String
        switch owner {
        case .bundleID(let id): name = id
        case .appGroup: name = owner.displayName
        }
        let lower = name.lowercased()
        guard !lower.isEmpty else { return false }
        guard !isAppleIdentifier(lower) else { return false }
        guard !DeletionSafetyPolicy.isProtectedContainerBundleID(name) else { return false }
        guard !AppUninstallScanPolicy.protectedBundleIDs.contains(where: {
            $0.lowercased() == lower
        }) else { return false }
        switch owner {
        case .bundleID(let id):
            return !installed.owns(bundleID: id)
        case .appGroup(let identifier, let teamID):
            return !installed.owns(appGroup: identifier, teamID: teamID)
        }
    }

    /// Apple ships a long tail of `com.apple.*` containers for system services
    /// whose "app" never sits in /Applications; none of them are the
    /// dragged-to-Trash third-party leftovers this feature targets. Apple's
    /// team-prefixed groups put the `com.apple.` part further in
    /// (`243LU875E5.groups.com.apple.podcasts`), so it is matched anywhere.
    nonisolated static func isAppleIdentifier(_ lowercased: String) -> Bool {
        lowercased.hasPrefix("com.apple.") || lowercased.contains(".com.apple.")
    }

    // MARK: Owner present again

    /// Whether the removed app is back: running from anywhere (a copy in
    /// Downloads, a disk image), or installed where Launch Services can see it.
    /// The uninstaller quits a running app before it moves anything; a leftover
    /// has no app to quit, so one whose owner is present is kept instead (#224).
    nonisolated static func isOwnerPresent(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: Owner extraction

    /// The owner of one entry directly inside an orphan root, or `nil` when the
    /// entry is not identifier-keyed (and so cannot be attributed).
    nonisolated static func candidateOwner(
        entryName name: String,
        category: UninstallCategory,
        url: URL
    ) -> LeftoverOwner? {
        switch category {
        case .applicationSupport:
            return applicationSupportBundleID(from: name, url: url).map(LeftoverOwner.bundleID)
        case .containers:
            return owningBundleIDForContainer(at: url, directoryName: name).map(LeftoverOwner.bundleID)
        case .groupContainers:
            return groupContainerOwner(from: name)
        case .caches:      // HTTPStorages
            return httpStorageBundleID(from: name).map(LeftoverOwner.bundleID)
        case .savedState:
            return savedStateBundleID(from: name).map(LeftoverOwner.bundleID)
        case .bundle, .preferences, .logs, .launchAgents, .launchDaemons, .homeFolderData, .other:
            // Not orphan roots. Home folder data comes from the catalog
            // (`dotFolderCandidates`), never from an entry's name.
            return nil
        }
    }

    /// Application Support is real app data, not a rebuildable cache, so this
    /// path stays conservative: only a direct child folder whose complete name is
    /// already a bundle identifier can be attributed to a removed app. Human
    /// names (`Docker`, `Google`, `Adobe`) are left alone because they are often
    /// shared across products.
    nonisolated static func applicationSupportBundleID(from name: String, url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              looksLikeBundleID(name) else {
            return nil
        }
        return name
    }

    /// A container directory is usually named by its bundle id. When it is named
    /// by a UUID instead (app extensions, and the App Store leftovers users
    /// report), the owning id lives in the container's metadata plist, which is
    /// only readable with Full Disk Access. A failed read returns `nil` so the
    /// entry is skipped rather than guessed at.
    nonisolated static func owningBundleIDForContainer(
        at url: URL,
        directoryName: String
    ) -> String? {
        if looksLikeBundleID(directoryName) { return directoryName }
        return containerMetadataIdentifier(at: url)
    }

    /// Reads `MCMMetadataInfo → MCMMetadataIdentifier` from a container's
    /// `.com.apple.containermanagerd.metadata.plist`. Both the nested and a
    /// flattened layout are tried; anything unexpected yields `nil`.
    nonisolated static func containerMetadataIdentifier(at containerURL: URL) -> String? {
        let plistURL = containerURL
            .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dict = object as? [String: Any] else { return nil }

        if let info = dict["MCMMetadataInfo"] as? [String: Any],
           let identifier = info["MCMMetadataIdentifier"] as? String,
           !identifier.isEmpty {
            return identifier
        }
        if let identifier = dict["MCMMetadataIdentifier"] as? String, !identifier.isEmpty {
            return identifier
        }
        return nil
    }

    /// The app group a `<teamID>.<name>` group container belongs to. The name
    /// after the team id is a developer-chosen app-group name, not a bundle id:
    /// OrbStack (`dev.kdrag0n.MacVirt`) keeps its data in
    /// `HUAQ24HBR6.dev.orbstack` (#197). So the result is checked against the
    /// team ids and app-group entitlements of installed code, never against
    /// bundle ids alone. Only names that look reverse-DNS are attributed, the
    /// same set as before #197, so this never offers a folder kind it did not.
    ///
    /// The `group.<name>` form is deliberately not handled: it carries no team
    /// id, and is routinely shared by an installed app and its extensions (for
    /// example a password manager and its Safari extension). Entitlements could
    /// attribute it, but code outside the places the evidence looks (an app on
    /// another volume that is not running) would leave a group it still uses
    /// looking orphaned, with no team to fall back on. Those containers are left
    /// alone rather than guessed at.
    nonisolated static func groupContainerOwner(from name: String) -> LeftoverOwner? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let teamID = String(name[..<dot])
        guard isTeamIdentifier(teamID) else { return nil }
        let groupName = String(name[name.index(after: dot)...])
        guard looksLikeBundleID(groupName) else { return nil }
        return .appGroup(name, teamID: teamID)
    }

    /// HTTPStorages entries are `<bundle id>` directories and `<bundle id>.binarycookies` files.
    nonisolated static func httpStorageBundleID(from name: String) -> String? {
        var candidate = name
        if candidate.hasSuffix(".binarycookies") {
            candidate = String(candidate.dropLast(".binarycookies".count))
        }
        return looksLikeBundleID(candidate) ? candidate : nil
    }

    /// Saved Application State entries are `<bundle id>.savedState`.
    nonisolated static func savedStateBundleID(from name: String) -> String? {
        guard name.hasSuffix(".savedState") else { return nil }
        let candidate = String(name.dropLast(".savedState".count))
        return looksLikeBundleID(candidate) ? candidate : nil
    }

    /// A 10-character alphanumeric Apple Team Identifier, the leading segment of
    /// most group-container names.
    nonisolated static func isTeamIdentifier(_ segment: String) -> Bool {
        segment.count == 10 && segment.allSatisfy {
            $0.isUppercase && $0.isLetter || $0.isNumber
        }
    }

    /// A reverse-DNS-looking identifier: at least two dot-separated segments, no
    /// empty segment, first character a letter, and not a bare UUID. This keeps
    /// UUID-named directories out of the name-based paths (they resolve through
    /// metadata instead).
    nonisolated static func looksLikeBundleID(_ value: String) -> Bool {
        guard UUID(uuidString: value) == nil else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        guard segments.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let first = value.first, first.isLetter else { return false }
        return true
    }

    // MARK: Human-named folders (#224)

    /// The owner of a human-named Library folder according to the ledger: an app
    /// the installed-apps scan saw match it by name, now gone. Biased to keep:
    /// any recorded owner still installed keeps the folder, and so does an
    /// installed app that carries the folder's name, whatever its id.
    nonisolated static func ledgerOwner(
        ofFolderAt url: URL,
        home: URL,
        ledger: LeftoverOwnerLedger,
        installed: InstalledAppIndex
    ) -> LeftoverOwnerLedger.Entry? {
        guard !installed.diskAppNames.contains(url.lastPathComponent.lowercased()) else { return nil }
        guard let relative = LeftoverOwnerLedger.relativePath(url, home: home) else { return nil }
        let owners = ledger.owners(ofFolder: relative)
        guard !owners.isEmpty,
              owners.allSatisfy({ isOrphan(.bundleID($0.bundleID), installed: installed) }) else { return nil }
        return owners.first
    }

    /// What Preferences and Caches say about which apps have been on this Mac:
    /// the bundle ids of `~/Library/Preferences/<id>.plist` files and
    /// `~/Library/Caches/<id>` folders. Neither location is offered here
    /// (Preferences by design, Caches through App Caches), but each carries the
    /// id its app wrote, which a human-named Application Support folder lacks.
    nonisolated struct LibraryIdentifierClues: Equatable, Sendable {
        var preferenceIDs: Set<String> = []
        var cacheIDs: Set<String> = []

        static func gather(home: URL) -> LibraryIdentifierClues {
            let fm = FileManager.default
            let lib = home.appendingPathComponent("Library", isDirectory: true)
            var clues = LibraryIdentifierClues()
            let preferences = (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("Preferences").path)) ?? []
            for name in preferences where name.hasSuffix(".plist") {
                let id = String(name.dropLast(".plist".count))
                if looksLikeBundleID(id) { clues.preferenceIDs.insert(id) }
            }
            let caches = (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("Caches").path)) ?? []
            for name in caches where looksLikeBundleID(name) {
                clues.cacheIDs.insert(name)
            }
            return clues
        }

        /// The ids, from either location, whose last part is `name`, compared
        /// case-insensitively. Each distinct id once.
        func identifiers(endingIn name: String) -> Set<String> {
            let lower = name.lowercased()
            var seen = Set<String>()
            var result = Set<String>()
            for id in preferenceIDs.union(cacheIDs) {
                guard id.split(separator: ".").last?.lowercased() == lower,
                      seen.insert(id.lowercased()).inserted else { continue }
                result.insert(id)
            }
            return result
        }
    }

    /// The owner of a human-named `Application Support` folder from clues
    /// elsewhere in Library: exactly one bundle id, in a Preferences plist or a
    /// Caches folder, whose last part is the folder's name, and no installed
    /// code owns it. Two independent clues, the folder and the id-named entry,
    /// are required; the folder's name alone is never enough (#197). Biased to
    /// keep: an installed app with the folder's name owns it, an id any
    /// installed code owns keeps it, Apple's ids are never orphans, and two
    /// candidate ids are ambiguous, so nothing is attributed.
    nonisolated static func crossEvidenceOwner(
        folderName: String,
        clues: LibraryIdentifierClues,
        installed: InstalledAppIndex
    ) -> String? {
        let lower = folderName.lowercased()
        guard !lower.isEmpty, !looksLikeBundleID(folderName) else { return nil }
        guard !installed.diskAppNames.contains(lower) else { return nil }
        let candidates = clues.identifiers(endingIn: folderName)
        guard candidates.count == 1, let id = candidates.first else { return nil }
        guard isOrphan(.bundleID(id), installed: installed) else { return nil }
        return id
    }

    /// Who an entry belonged to and what says so. Identifier-named entries are
    /// attributed by their name alone, as before #224. A human-named
    /// `Application Support` folder needs the ledger, or a Preferences or Caches
    /// identifier, to vouch for it.
    nonisolated struct Attribution: Equatable {
        let owner: LeftoverOwner
        let evidence: MatchReason
        /// The app's name when the evidence knows it. Otherwise the row falls
        /// back to `friendlyName`.
        let appName: String?
    }

    nonisolated static func attribution(
        entryName name: String,
        category: UninstallCategory,
        url: URL,
        home: URL,
        installed: InstalledAppIndex,
        ledger: LeftoverOwnerLedger,
        clues: LibraryIdentifierClues
    ) -> Attribution? {
        if let owner = candidateOwner(entryName: name, category: category, url: url) {
            return Attribution(owner: owner, evidence: .bundleID, appName: nil)
        }
        guard category == .applicationSupport, isHumanNamedFolder(name, url: url) else { return nil }
        if let entry = ledgerOwner(ofFolderAt: url, home: home, ledger: ledger, installed: installed) {
            return Attribution(owner: .bundleID(entry.bundleID), evidence: .ownerLedger, appName: entry.displayName)
        }
        if let id = crossEvidenceOwner(folderName: name, clues: clues, installed: installed) {
            // The folder's own name is the best name for the app here.
            return Attribution(owner: .bundleID(id), evidence: .libraryCrossEvidence, appName: name)
        }
        return nil
    }

    /// A folder whose name is not an identifier: `Antigravity`, `Docker`.
    nonisolated static func isHumanNamedFolder(_ name: String, url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard !name.isEmpty, !looksLikeBundleID(name), UUID(uuidString: name) == nil,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return true
    }

    // MARK: Dot folders (#224)

    /// One hidden home folder of a removed app, from the catalog.
    nonisolated struct DotFolderCandidate: Equatable {
        let url: URL
        let entry: AppDotFolderCatalog.Entry
        let lastModified: Date
    }

    /// The catalog folders of apps that are gone, untouched since `cutoff`. A
    /// candidate is always a folder the catalog names in full; a parent shared
    /// with other tools, such as `~/.gemini`, is never one. A missing folder, a
    /// file, or a symbolic link in its place is skipped.
    nonisolated static func dotFolderCandidates(
        catalog: AppDotFolderCatalog,
        home: URL,
        installed: InstalledAppIndex,
        cutoff: Date
    ) -> [DotFolderCandidate] {
        var result: [DotFolderCandidate] = []
        for entry in catalog.entries where isOrphan(.bundleID(entry.bundleID), installed: installed) {
            for folder in entry.folders {
                guard let url = catalog.url(for: folder, home: home) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                guard case .untouchedSince(let date) = contentAge(of: url, cutoff: cutoff) else { continue }
                result.append(DotFolderCandidate(url: url, entry: entry, lastModified: date))
            }
        }
        return result
    }

    // MARK: Staleness

    /// The untouched window an orphan must exceed before it is offered, reusing
    /// the Developer Projects "Consider stale after" control. Removed apps go to
    /// a data tier that does not come back, so a mid-reinstall or just-quit app
    /// must never be swept. When the control is set to "Show all", the orphan
    /// scan still keeps a 30-day safety buffer instead of offering fresh data.
    /// Until the user picks an age, the buffer alone applies: the 6 months Developer
    /// Projects assumes is longer than leftovers, always Check First, need.
    nonisolated static func effectiveStaleDays(userDefaults: UserDefaults = .standard) -> Int {
        guard userDefaults.object(forKey: DevToolsStalenessOption.userDefaultsKey) != nil else {
            return minimumStaleDaysFloor
        }
        let configured = DevToolsStalenessOption.currentThresholdDays(userDefaults: userDefaults)
        let base = configured == 0 ? minimumStaleDaysFloor : configured
        return max(base, minimumStaleDaysFloor)
    }

    nonisolated static let minimumStaleDaysFloor = 30

    /// The moment a leftover must have gone untouched since.
    nonisolated static func staleCutoff(staleDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(staleDays) * 24 * 60 * 60)
    }

    // MARK: Decision

    /// One entry the scan offers: who it belonged to, what says so, and when
    /// anything in it last changed.
    nonisolated struct OrphanCandidate: Equatable {
        let owner: LeftoverOwner
        let evidence: MatchReason
        /// Known from the evidence, or nil for the row to resolve.
        let appName: String?
        let lastModified: Date
    }

    /// The scan's whole decision for one entry directly inside an orphan root,
    /// short of the delete gate the scanner applies afterwards: its owner can
    /// be named, no installed code claims it, and nothing in it changed since
    /// `cutoff`. Kept in one function so a test fails if any part is dropped.
    /// With no ledger and no clues, only identifier-named entries are attributed.
    nonisolated static func orphanCandidate(
        at entry: URL,
        category: UninstallCategory,
        installed: InstalledAppIndex,
        cutoff: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        ledger: LeftoverOwnerLedger = LeftoverOwnerLedger(),
        clues: LibraryIdentifierClues = LibraryIdentifierClues()
    ) -> OrphanCandidate? {
        guard let attribution = attribution(
            entryName: entry.lastPathComponent,
            category: category,
            url: entry,
            home: home,
            installed: installed,
            ledger: ledger,
            clues: clues
        ),
              isOrphan(attribution.owner, installed: installed),
              case .untouchedSince(let lastModified) = contentAge(of: entry, cutoff: cutoff) else {
            return nil
        }
        return OrphanCandidate(
            owner: attribution.owner,
            evidence: attribution.evidence,
            appName: attribution.appName,
            lastModified: lastModified
        )
    }

    // MARK: Content age

    /// When anything inside a leftover was last changed, judged against `cutoff`.
    nonisolated enum ContentAge: Equatable {
        /// Something inside changed at or after the cutoff: still in use.
        case recent
        /// Nothing inside changed after this date, which is before the cutoff.
        case untouchedSince(Date)
        /// The walk could not finish (an unreadable item, a missing date, too
        /// many items, a cancelled scan), so the age is not known.
        case unknown
    }

    /// Files whose date says nothing about use: Finder writes `.DS_Store` when
    /// someone opens the folder, and macOS keeps the container metadata plist
    /// itself.
    nonisolated static let contentAgeIgnoredNames: Set<String> = [
        ".DS_Store",
        ".com.apple.containermanagerd.metadata.plist"
    ]

    /// How much later a folder's date may be than an ignored file inside it and
    /// still be explained by writing that file. A file written in place and then
    /// moved into the folder leaves the folder a moment newer than the file.
    nonisolated static let ignoredFileDateTolerance: TimeInterval = 2

    /// A guard against a runaway walk, not a product limit.
    nonisolated static let contentAgeEntryLimit = 500_000

    /// The age of everything inside `url`, not just the folder's own date. A
    /// folder's date only changes when an entry directly inside it is added,
    /// removed, or renamed, so an app writing deep inside (OrbStack's disk image,
    /// Telegram's database) leaves it months old while in daily use. Stops at the
    /// first file changed at or after `cutoff`.
    ///
    /// Folder dates still count, because removing or renaming a file changes
    /// nothing else. But writing an ignored file also sets its folder's date,
    /// so opening a real leftover in Finder would hide it. A recent folder date
    /// is therefore set aside until the walk has seen the folder's entries, and
    /// dropped when an ignored file inside is at least as new.
    ///
    /// Symbolic links are skipped: old sandbox containers link to Desktop and
    /// Downloads, whose dates say nothing about the app. Anything the walk
    /// cannot read or date makes the age unknown, which the scan treats as in
    /// use.
    nonisolated static func contentAge(
        of url: URL,
        cutoff: Date,
        entryLimit: Int = contentAgeEntryLimit
    ) -> ContentAge {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        // A URL keeps the values it was listed with; read the date as it is now.
        var url = url
        url.removeAllCachedResourceValues()
        guard let top = try? url.resourceValues(forKeys: keys),
              let topDate = top.contentModificationDate,
              topDate > .distantPast else { return .unknown }
        guard top.isDirectory == true, top.isSymbolicLink != true else {
            return topDate >= cutoff ? .recent : .untouchedSince(topDate)
        }

        // Folders whose own date is recent and not yet explained, by resolved
        // path: the enumerator can spell `/var` as `/private/var`.
        var unexplainedFolders: [String: Date] = [:]
        func folderKey(_ folder: URL) -> String {
            folder.standardizedFileURL.resolvingSymlinksInPath().path
        }
        var newest = Date.distantPast
        if topDate >= cutoff {
            unexplainedFolders[folderKey(url)] = topDate
        } else {
            newest = topDate
        }

        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                failed = true
                return false
            }
        ) else { return .unknown }

        var seen = 0
        for case let item as URL in enumerator {
            seen += 1
            if seen > entryLimit || Task.isCancelled { return .unknown }
            guard let values = try? item.resourceValues(forKeys: keys) else { return .unknown }
            if values.isSymbolicLink == true { continue }
            guard let date = values.contentModificationDate, date > .distantPast else { return .unknown }
            if contentAgeIgnoredNames.contains(item.lastPathComponent) {
                let parent = folderKey(item.deletingLastPathComponent())
                if let folderDate = unexplainedFolders[parent],
                   folderDate <= date.addingTimeInterval(ignoredFileDateTolerance) {
                    unexplainedFolders[parent] = nil
                }
                continue
            }
            if values.isDirectory == true {
                if date >= cutoff {
                    unexplainedFolders[folderKey(item)] = date
                } else if date > newest {
                    newest = date
                }
                continue
            }
            if date >= cutoff { return .recent }
            if date > newest { newest = date }
        }
        if failed { return .unknown }
        if !unexplainedFolders.isEmpty { return .recent }
        // Only ignored files, so nothing says how old the folder really is.
        guard newest > .distantPast else { return .unknown }
        return .untouchedSince(newest)
    }

    // MARK: Presentation

    /// A friendly name for the removed app: the folder's Finder-resolved name
    /// when it is meaningful (macOS resolves it from the same container metadata),
    /// otherwise the bundle id itself. Finder hides a `.app` extension, so for
    /// `com.granola.app` it answers `com.granola`, which is the folder's own name
    /// with its extension gone, not a resolved name; that reads as the id too.
    nonisolated static func friendlyName(bundleID: String, url: URL) -> String {
        let name = url.lastPathComponent
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localized.isEmpty,
           localized != name,
           localized != (name as NSString).deletingPathExtension,
           UUID(uuidString: localized) == nil {
            return (localized as NSString).deletingPathExtension
        }
        return bundleID
    }

    /// Orphan data is always the "Check First" tier and never preselected. Unlike
    /// a cache, it does not regenerate, and there is no reinstall-safety evidence
    /// to prove nobody will miss it, so the user opts in per item.
    nonisolated static func safetyInfo(
        appName: String,
        category: UninstallCategory
    ) -> SafetyInfo {
        let explanation = category == .homeFolderData
            ? String(localized: "This hidden folder in your home folder was written by \(appName), which is no longer installed. It is app data, not a rebuildable cache, so it will not come back on its own. Remove it only if you are sure you will not reinstall this app.")
            : String(localized: "This \(category.displayName.lowercased()) folder belongs to an app that is no longer installed. It is app data, not a rebuildable cache, so it will not come back on its own. Remove it only if you are sure you will not reinstall this app.")
        return SafetyInfo(
            level: .medium,
            // No "leftover from a removed app" suffix here: the section and the
            // review sheet already say so, so on the row it is only noise.
            headline: appName,
            explanation: explanation,
            recoverySteps: String(localized: "Removed items go to the Trash, so you can put them back until you empty it. If you reinstall the app, let it recreate its data."),
            reinstallCommand: nil
        )
    }
}
