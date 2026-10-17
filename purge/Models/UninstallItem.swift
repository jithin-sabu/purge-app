import Foundation

/// Where a leftover lives, which groups the review list and picks the row icon.
/// `.bundle` is the `.app` itself; the rest are the support-file locations from
/// issue #45.
nonisolated enum UninstallCategory: String, CaseIterable, Identifiable, Hashable {
    case bundle
    case applicationSupport
    case caches
    case preferences
    case containers
    case groupContainers
    case savedState
    case logs
    case launchAgents
    case launchDaemons
    /// A hidden folder an app keeps in the home folder, named by the catalog in
    /// `app-dot-folders.json` (#224). Only the Leftovers scan produces it.
    case homeFolderData
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bundle: return String(localized: "Application")
        case .applicationSupport: return String(localized: "Application Support")
        case .caches: return String(localized: "Caches")
        case .preferences: return String(localized: "Preferences")
        case .containers: return String(localized: "Containers")
        case .groupContainers: return String(localized: "Group Containers")
        case .savedState: return String(localized: "Saved State")
        case .logs: return String(localized: "Logs")
        case .launchAgents: return String(localized: "Launch Agents")
        case .launchDaemons: return String(localized: "Launch Daemons")
        case .homeFolderData: return String(localized: "Home Folder Data")
        case .other: return String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .bundle: return "app.dashed"
        case .applicationSupport: return "folder"
        case .caches: return "internaldrive"
        case .preferences: return "slider.horizontal.3"
        case .containers: return "shippingbox"
        case .groupContainers: return "square.stack.3d.up"
        case .savedState: return "clock.arrow.circlepath"
        case .logs: return "doc.text"
        case .launchAgents: return "bolt.badge.clock"
        case .launchDaemons: return "bolt.horizontal"
        case .homeFolderData: return "house"
        case .other: return "doc"
        }
    }

    /// Ordering in the review list: the bundle first, then the heavy data
    /// locations, then the small config and startup entries.
    var sortOrder: Int {
        switch self {
        case .bundle: return 0
        case .applicationSupport: return 1
        case .homeFolderData: return 2
        case .containers: return 3
        case .groupContainers: return 4
        case .caches: return 5
        case .savedState: return 6
        case .logs: return 7
        case .preferences: return 8
        case .launchAgents: return 9
        case .launchDaemons: return 10
        case .other: return 11
        }
    }
}

/// Why a path was linked to the chosen app. This is shown on the row so the
/// user can see the strength of the link, and it drives the safety level:
/// bundle-id anchored matches are `.safe`, name-only matches are `.medium`.
nonisolated enum MatchReason: Hashable {
    /// The `.app` bundle the user picked.
    case appBundle
    /// Path is anchored to the app's bundle identifier, e.g.
    /// `Preferences/com.vendor.App.plist` or `Containers/com.vendor.App`.
    case bundleID
    /// Path is anchored to a group-container identifier that clearly contains the
    /// app's bundle-id stem.
    case groupID
    /// Folder or file name equals the app's display name, e.g.
    /// `Application Support/Rectangle`. Weaker, because vendors reuse names.
    case appName
    /// A human-named folder the installed-apps scan saw this app match by name
    /// while the app was installed, recorded in the owner ledger (#224). Only
    /// the Leftovers scan produces it, once the app is gone.
    case ownerLedger
    /// A human-named `Application Support` folder whose name is the last part of
    /// a bundle id found in Preferences or Caches, where no installed code owns
    /// that id: `Antigravity` and `com.google.antigravity.plist` (#224).
    case libraryCrossEvidence
    /// A hidden home folder the catalog in `app-dot-folders.json` names for an
    /// app that is no longer installed (#224).
    case dotFolderCatalog

    /// Bundle-id and group-id anchoring are strong enough to preselect; a name
    /// match is offered but left for the user to confirm. Leftovers of removed
    /// apps are never preselected, whatever attributed them.
    var isHighConfidence: Bool {
        switch self {
        case .appBundle, .bundleID, .groupID: return true
        case .appName, .ownerLedger, .libraryCrossEvidence, .dotFolderCatalog: return false
        }
    }

    var rowNote: String {
        switch self {
        case .appBundle: return String(localized: "The application itself")
        case .bundleID: return String(localized: "Matched by bundle identifier")
        case .groupID: return String(localized: "Matched by app group")
        case .appName: return String(localized: "Matched by name, check this belongs to the app")
        case .ownerLedger: return String(localized: "Seen in use by this app while it was installed")
        case .libraryCrossEvidence: return String(localized: "Named like this app's Preferences or Caches identifier")
        case .dotFolderCatalog: return String(localized: "A hidden folder this app is known to keep")
        }
    }
}

/// One removable path in the uninstall review list. Carries the same fields the
/// existing scan rows and deletion path expect, so `ScanResultRow` and the Trash
/// engine accept it with no special casing.
nonisolated struct UninstallItem: Identifiable, Hashable {
    var id: String { path.standardizedFileURL.path }
    let path: URL
    var sizeBytes: Int64
    let category: UninstallCategory
    let safetyInfo: SafetyInfo
    let matchReason: MatchReason
    var isSelected: Bool
    /// The name of another still-installed app that also claims this path, set
    /// when the plan is built. Non-nil means the item is shared with an app the
    /// user is keeping, so it starts unticked and the deletion pass holds it back
    /// rather than stripping a file the surviving app still reads. `nil` for the
    /// common case of a path only this app owns.
    var keptForApp: String? = nil
    /// Last-modified date of the path, used to sort the leftovers list by age.
    /// The app-uninstaller flow does not sort by date, so it leaves this at the
    /// default.
    var lastModified: Date = .distantPast
    /// The bundle ids of the removed apps a leftover belonged to, the row's owner
    /// first, when the evidence names any (#224). The ledger can name more than
    /// one gone app for a folder. The confirm step checks that none of them is
    /// running or back on this Mac before anything moves. Empty for the
    /// uninstaller's own items, whose app is the one being removed, and for app
    /// groups.
    var ownerBundleIDs: [String] = []

    /// Shared with an app that is staying installed, so it must not be trashed.
    var isKeptForOtherApp: Bool { keptForApp != nil }

    /// Whether the per-app header checkbox in the review sheet ticks this row.
    /// A row kept for a surviving app is locked off. A catalog dot folder (#228)
    /// holds settings, extensions and history, so only a click on its own row
    /// ticks it; the header never sweeps it in. The header can still clear it,
    /// see `UninstallAppPlan.toggleAllFromHeader`.
    var isTickedByHeader: Bool { !isKeptForOtherApp && category != .homeFolderData }

    var formattedSize: String { formatBytes(sizeBytes) }
}

/// The two views inside the App Uninstaller tab. `leftovers` only exists as a
/// switchable segment once a scan finds any (issue #26). Lives here rather than
/// in the view so `PurgeStore` can own the current selection and the tab's
/// header can swap its action button to match.
nonisolated enum UninstallSection: String, CaseIterable, Identifiable {
    case installedApps
    case leftovers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .installedApps: return String(localized: "Installed Apps")
        case .leftovers: return String(localized: "Leftovers")
        }
    }

    var symbolName: String {
        switch self {
        case .installedApps: return "square.grid.2x2"
        case .leftovers: return "clock.badge.xmark"
        }
    }
}

/// An app the Uninstall an App intent opened the uninstaller on. The id is
/// `InstalledApp.id`; the name goes in the search box.
nonisolated struct UninstallerFocus: Equatable {
    let appID: String
    let name: String
}

/// The reviewed orphan-leftover removal awaiting confirmation (issue #26). Unlike
/// `UninstallPlan`, there is no app: every item is a leftover whose owner is gone,
/// so it is a flat list. Each item keeps its own `isSelected` so the review sheet
/// can tick and untick within it.
nonisolated struct OrphanCleanupPlan: Identifiable, Hashable {
    var items: [UninstallItem]

    /// Stable across reopenings of the same set, so `.sheet(item:)` presents one
    /// sheet per distinct selection.
    var id: String { items.map(\.id).sorted().joined(separator: "|") }

    var selectedItems: [UninstallItem] { items.filter(\.isSelected) }
    var totalSelectedItems: Int { selectedItems.count }
    var totalSelectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

/// The leftovers of an app that left the Applications folders outside Purge,
/// awaiting review (issue #65). The app is already gone, so there is no bundle
/// row: every item is a support file it left behind.
nonisolated struct RemovedAppLeftoverPlan: Identifiable, Hashable {
    let app: InstalledApp
    var items: [UninstallItem]
    /// The bundle's copy in the Trash, when there is one to take an icon from.
    var trashedBundleURL: URL?

    var id: String { app.id }

    var selectedItems: [UninstallItem] { items.filter(\.isSelected) }
    var totalSelectedItems: Int { selectedItems.count }
    var totalSelectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

/// One app in a multi-app removal: the app and its bundle-plus-leftover items,
/// each item carrying its own `isSelected` so the review sheet can tick and
/// untick within an app.
nonisolated struct UninstallAppPlan: Identifiable, Hashable {
    let app: InstalledApp
    var items: [UninstallItem]

    var id: String { app.id }

    var selectedItems: [UninstallItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    /// What the per-app header checkbox shows.
    enum HeaderSelection {
        case none
        case mixed
        case all
    }

    /// The header state, over the rows the header ticks (`isTickedByHeader`).
    /// A catalog dot folder is left out of the count, so a plan whose only
    /// unticked row is that folder reads as `.all`, and one click clears the
    /// list as it did before #228 instead of ticking the folder.
    var headerSelection: HeaderSelection {
        let counted = items.filter(\.isTickedByHeader)
        guard !counted.isEmpty else { return .none }
        let selected = counted.filter(\.isSelected).count
        if selected == 0 { return .none }
        if selected == counted.count { return .all }
        return .mixed
    }

    /// A click on the header checkbox. When every header row is ticked, it
    /// clears every row that is not locked, a ticked dot folder included, since
    /// clearing is the safer direction. Otherwise it ticks the header rows only,
    /// and a dot folder keeps whatever the user set on its own row.
    mutating func toggleAllFromHeader() {
        let allOn = headerSelection == .all
        for index in items.indices where !items[index].isKeptForOtherApp {
            if allOn {
                items[index].isSelected = false
            } else if items[index].isTickedByHeader {
                items[index].isSelected = true
            }
        }
    }
}

/// The reviewed removal across every selected app. `id` is derived from the app
/// ids so `.sheet(item:)` presents one sheet per distinct selection.
nonisolated struct UninstallPlan: Identifiable, Hashable {
    let id: String
    var apps: [UninstallAppPlan]

    var totalSelectedItems: Int { uniqueSelectedItems.count }
    var totalSelectedBytes: Int64 { uniqueSelectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    /// The checked items across every app, with any path selected under more than
    /// one app counted once. Two installs that share a bundle id (Xcode and
    /// Xcode-beta) resolve to the same bundle-id-keyed leftovers, so a naive
    /// per-app sum would double the figure the sheet shows and the bytes trashed.
    private var uniqueSelectedItems: [UninstallItem] {
        var seen = Set<String>()
        var result: [UninstallItem] = []
        for app in apps {
            for item in app.selectedItems where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }
}
