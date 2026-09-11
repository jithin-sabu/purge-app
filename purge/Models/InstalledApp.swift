import Foundation

/// One application the uninstaller can act on. Built by `AppUninstallScanner`
/// from the app roots, never from `/System`, so a row here is always something
/// the user installed and is allowed to remove.
nonisolated struct InstalledApp: Identifiable, Hashable {
    /// The bundle path, which is always unique. Deliberately not the bundle id:
    /// two installs can share one (Xcode and Xcode-beta are both
    /// `com.apple.dt.Xcode`), and keying identity on that collapses them into a
    /// single grid cell. The bundle id is still the leftover match anchor below.
    var id: String { bundleURL.standardizedFileURL.path }

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
    /// When the bundle landed on this volume, the closest proxy for "installed on".
    /// Defaults to `.distantPast` so a bundle whose date can't be read sorts last
    /// under "recently installed".
    var dateAdded: Date = .distantPast

    /// The stem used for name-based leftover matching, e.g. "Rectangle". Kept
    /// separate from `name` so a future display tweak cannot loosen matching.
    var matchName: String { name }

    var formattedSize: String { formatBytes(bundleSizeBytes) }
}
