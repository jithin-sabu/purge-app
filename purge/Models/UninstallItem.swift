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
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bundle: return "Application"
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .preferences: return "Preferences"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .savedState: return "Saved State"
        case .logs: return "Logs"
        case .launchAgents: return "Launch Agents"
        case .launchDaemons: return "Launch Daemons"
        case .other: return "Other"
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
        case .other: return "doc"
        }
    }

    /// Ordering in the review list: the bundle first, then the heavy data
    /// locations, then the small config and startup entries.
    var sortOrder: Int {
        switch self {
        case .bundle: return 0
        case .applicationSupport: return 1
        case .containers: return 2
        case .groupContainers: return 3
        case .caches: return 4
        case .savedState: return 5
        case .logs: return 6
        case .preferences: return 7
        case .launchAgents: return 8
        case .launchDaemons: return 9
        case .other: return 10
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

    /// Bundle-id and group-id anchoring are strong enough to preselect; a name
    /// match is offered but left for the user to confirm.
    var isHighConfidence: Bool {
        switch self {
        case .appBundle, .bundleID, .groupID: return true
        case .appName: return false
        }
    }

    var rowNote: String {
        switch self {
        case .appBundle: return "The application itself"
        case .bundleID: return "Matched by bundle identifier"
        case .groupID: return "Matched by app group"
        case .appName: return "Matched by name, check this belongs to the app"
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

    /// Shared with an app that is staying installed, so it must not be trashed.
    var isKeptForOtherApp: Bool { keptForApp != nil }

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
        case .installedApps: return "Installed Apps"
        case .leftovers: return "Leftovers"
        }
    }

    var symbolName: String {
        switch self {
        case .installedApps: return "square.grid.2x2"
        case .leftovers: return "clock.badge.xmark"
        }
    }
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

/// One app in a multi-app removal: the app and its bundle-plus-leftover items,
/// each item carrying its own `isSelected` so the review sheet can tick and
/// untick within an app.
nonisolated struct UninstallAppPlan: Identifiable, Hashable {
    let app: InstalledApp
    var items: [UninstallItem]

    var id: String { app.id }

    var selectedItems: [UninstallItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }
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
