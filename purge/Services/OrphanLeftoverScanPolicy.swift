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
    /// launch-item roots are also left out of v1 — they are tiny, noisy, and full
    /// of daemon/helper identifiers that never appear as apps, which is exactly
    /// where a wrong "orphaned" call is most likely.
    nonisolated struct OrphanRoot {
        let url: URL
        let category: UninstallCategory
    }

    nonisolated static func orphanRoots(home: URL) -> [OrphanRoot] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        return [
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

    /// The set of installed application bundle identifiers, used to decide whether
    /// a leftover's owner is still present. `owns` treats the set as prefixes so a
    /// helper or extension id (`com.vendor.App.Helper`) is owned whenever its
    /// parent app (`com.vendor.App`) is installed.
    nonisolated struct InstalledAppIndex {
        /// Lowercased bundle ids of `.app` bundles found on disk in the user's app
        /// roots. Used both for ownership and for the completeness check.
        let diskBundleIDs: Set<String>

        var appCount: Int { diskBundleIDs.count }

        /// Guards against acting on a broken view of the world: an unmounted
        /// volume, an unreadable `/Applications`, or a sandbox with no Launch
        /// Services access all read as "almost nothing installed", which would
        /// flag every leftover as orphaned. Below the floor, the scan suppresses
        /// itself rather than produce a false list.
        var looksComplete: Bool { appCount >= minimumPlausibleAppCount }

        /// Whether an installed app owns this bundle id, by exact match or by
        /// being a parent of it. Biased toward owned: it tests the id and each
        /// parent prefix down to two components, and a hit anywhere means "keep".
        func owns(bundleID: String) -> Bool {
            let lower = bundleID.lowercased()
            var components = lower.split(separator: ".").map(String.init)
            while components.count >= 2 {
                let candidate = components.joined(separator: ".")
                if diskBundleIDs.contains(candidate) { return true }
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
    }

    /// Fewer installed apps than this and the scan refuses to run — see
    /// `looksComplete`.
    nonisolated static let minimumPlausibleAppCount = 5

    /// Enumerates `.app` bundle identifiers in the user-facing app roots, one
    /// level deep (vendors group their apps, e.g. `/Applications/Utilities/…`).
    /// System apps are not walked: `owns` reaches them through LaunchServices,
    /// and counting them would inflate `looksComplete` past the point where it
    /// can catch an empty world.
    nonisolated static func makeInstalledAppIndex() -> InstalledAppIndex {
        let fm = FileManager.default
        var ids = Set<String>()

        func collect(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            if let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty {
                ids.insert(id.lowercased())
            }
        }

        for root in AppUninstallScanPolicy.installedAppRoots() {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    collect(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for child in nested { collect(child) }
                }
            }
        }
        return InstalledAppIndex(diskBundleIDs: ids)
    }

    // MARK: Orphan test

    /// Whether a leftover keyed by `bundleID` should be treated as orphaned.
    /// Never true for Apple's own identifiers, protected containers, or Purge
    /// itself, and never true when an installed app owns the id.
    nonisolated static func isOrphan(bundleID: String, installed: InstalledAppIndex) -> Bool {
        let lower = bundleID.lowercased()
        guard !lower.isEmpty else { return false }
        // Apple ships a long tail of `com.apple.*` containers for system services
        // whose "app" never sits in /Applications; none of them are the
        // dragged-to-Trash third-party leftovers this feature targets.
        guard !lower.hasPrefix("com.apple.") else { return false }
        guard !DeletionSafetyPolicy.isProtectedContainerBundleID(bundleID) else { return false }
        guard !AppUninstallScanPolicy.protectedBundleIDs.contains(where: {
            $0.lowercased() == lower
        }) else { return false }
        return !installed.owns(bundleID: bundleID)
    }

    // MARK: Bundle-id extraction

    /// The owning bundle id for one entry directly inside an orphan root, or `nil`
    /// when the entry is not identifier-keyed (and so cannot be attributed).
    nonisolated static func candidateBundleID(
        entryName name: String,
        category: UninstallCategory,
        url: URL
    ) -> String? {
        switch category {
        case .containers:
            return owningBundleIDForContainer(at: url, directoryName: name)
        case .groupContainers:
            return groupContainerBundleID(from: name)
        case .caches:      // HTTPStorages
            return httpStorageBundleID(from: name)
        case .savedState:
            return savedStateBundleID(from: name)
        default:
            return nil
        }
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

    /// Group containers are `<teamID>.<bundle id>` or `group.<bundle id>`. The
    /// bundle id is what remains after the prefix; anything that does not then
    /// look like a bundle id is rejected.
    nonisolated static func groupContainerBundleID(from name: String) -> String? {
        let candidate: String
        if name.lowercased().hasPrefix("group.") {
            candidate = String(name.dropFirst("group.".count))
        } else if let dot = name.firstIndex(of: "."), isTeamIdentifier(String(name[..<dot])) {
            candidate = String(name[name.index(after: dot)...])
        } else {
            return nil
        }
        return looksLikeBundleID(candidate) ? candidate : nil
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

    // MARK: Staleness

    /// The untouched window an orphan must exceed before it is offered, reusing
    /// the Developer Projects "Consider stale after" control. Removed apps go to
    /// a data tier that does not come back, so a mid-reinstall or just-quit app
    /// must never be swept: when the control is set to "Show all" (no gate), this
    /// falls back to the default window rather than zero, and a 30-day floor
    /// applies in every case.
    nonisolated static func effectiveStaleDays(userDefaults: UserDefaults = .standard) -> Int {
        let configured = DevToolsStalenessOption.currentThresholdDays(userDefaults: userDefaults)
        let base = configured == 0 ? DevToolsStalenessOption.defaultOption.rawValue : configured
        return max(base, minimumStaleDaysFloor)
    }

    nonisolated static let minimumStaleDaysFloor = 30

    /// Whether a leftover has gone untouched for at least `staleDays`. An
    /// undeterminable modification date reads as *not* stale, so an entry Purge
    /// cannot date is left alone rather than offered.
    nonisolated static func isStale(
        modifiedAt date: Date,
        staleDays: Int,
        now: Date = Date()
    ) -> Bool {
        guard staleDays > 0 else { return true }
        guard date > .distantPast else { return false }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return false }
        let days = seconds / (24 * 60 * 60)
        return days >= Double(staleDays)
    }

    // MARK: Presentation

    /// A friendly name for the removed app: the folder's Finder-resolved name
    /// when it is meaningful (macOS resolves it from the same container metadata),
    /// otherwise the bundle id itself.
    nonisolated static func friendlyName(bundleID: String, url: URL) -> String {
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localized.isEmpty,
           localized != url.lastPathComponent,
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
        SafetyInfo(
            level: .medium,
            // No "leftover from a removed app" suffix here: the section and the
            // review sheet already say so, so on the row it is only noise.
            headline: appName,
            explanation: "This \(category.displayName.lowercased()) folder belongs to an app that is no longer installed. It is app data, not a rebuildable cache, so it will not come back on its own. Remove it only if you are sure you will not reinstall this app.",
            recoverySteps: "Removed items go to the Trash, so you can put them back until you empty it. If you reinstall the app, let it recreate its data.",
            reinstallCommand: nil
        )
    }
}
