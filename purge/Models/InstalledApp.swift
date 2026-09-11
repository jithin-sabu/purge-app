import Foundation

/// One application the uninstaller can act on. Built by `AppUninstallScanner`
/// from the app roots, never from `/System`, so a row here is always something
/// the user installed and is allowed to remove.
nonisolated struct InstalledApp: Identifiable, Hashable {
    /// Bundle identifier when the app has one, otherwise the bundle path. Used as
    /// the stable list identity and as the match anchor for finding leftovers.
    var id: String { bundleID ?? bundleURL.standardizedFileURL.path }

    /// Display name, e.g. "Rectangle".
    let name: String
    /// Location of the `.app` bundle, e.g. `/Applications/Rectangle.app`.
    let bundleURL: URL
    /// Reverse-DNS identifier, e.g. `com.knollsoft.Rectangle`. Absent on a few
    /// older or malformed bundles, which fall back to name-only matching.
    let bundleID: String?
    /// Size of the `.app` bundle on disk. Zero until the sizing pass resolves it.
    var bundleSizeBytes: Int64
    /// True when the app is running now, so the uninstall flow can offer to quit
    /// it before trashing the bundle.
    let isRunning: Bool

    /// The stem used for name-based leftover matching, e.g. "Rectangle". Kept
    /// separate from `name` so a future display tweak cannot loosen matching.
    var matchName: String { name }

    var formattedSize: String { formatBytes(bundleSizeBytes) }
}
