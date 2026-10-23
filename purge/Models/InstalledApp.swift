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
    /// When the user last opened the app, from Spotlight (`kMDItemLastUsedDate`).
    /// Nil when macOS has no record. That is not the same as the bundle's
    /// modification date, which moves on every update.
    var lastOpened: Date? = nil
    /// Set when Homebrew installed this app as a cask (#254), read from the
    /// Caskroom link that points at the bundle. The review sheet then offers to
    /// remove the app through Homebrew, which deletes it permanently.
    var homebrewCask: HomebrewCask? = nil

    /// The stem used for name-based leftover matching, e.g. "Rectangle". Kept
    /// separate from `name` so a future display tweak cannot loosen matching.
    var matchName: String { name }

    var formattedSize: String { formatBytes(bundleSizeBytes) }
}

/// An app Homebrew installed as a cask (#254). `token` is the Caskroom folder
/// name, which is also the name `brew uninstall --cask` takes.
nonisolated struct HomebrewCask: Hashable, Sendable {
    let token: String
    /// The Homebrew prefix whose Caskroom lists it: `/opt/homebrew` on Apple
    /// silicon, `/usr/local` on Intel.
    let prefix: URL

    var brewExecutable: URL { prefix.appendingPathComponent("bin/brew") }

    /// The command as people type it, for the review sheet. Spelled out here
    /// because the watch agent compiles this file without `PackageManager`;
    /// `HomebrewCaskCatalogTests` keeps it equal to the manager's prefix.
    var command: String { "brew uninstall --cask \(token)" }
}
