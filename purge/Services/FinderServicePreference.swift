import Combine
import Foundation

/// The Settings switch for "Uninstall with Purge" in Finder's right-click menu.
///
/// macOS starts a third-party app's Finder service switched off, and the only
/// place to turn it on is System Settings > Keyboard > Keyboard Shortcuts >
/// Services. That choice is stored per service in the `pbs` preferences domain
/// (`~/Library/Preferences/pbs.plist`), under `NSServicesStatus`, keyed by
/// bundle id, menu title and message. This writes the same entry System
/// Settings writes, for Purge's own service only, and then flushes the Services
/// cache, without which Finder keeps showing the old state until the next
/// login (verified 2026-10-09 on macOS 27).
///
/// The format is undocumented, so the switch reads the real state back after
/// every write rather than trusting it, and `refresh()` runs whenever Settings
/// comes into view in case the person changed it in System Settings.
@MainActor
final class FinderServicePreference: ObservableObject {
    static let shared = FinderServicePreference(
        defaults: UserDefaults(suiteName: domain) ?? .standard,
        statusKey: statusKey(bundleID: Bundle.main.bundleIdentifier ?? "io.getpurge.app"),
        flush: flushServicesCache
    )

    /// The preferences domain of pbs, the Services agent.
    nonisolated static let domain = "pbs"
    nonisolated static let statusDictionaryKey = "NSServicesStatus"
    nonisolated static let contextMenuKey = "enabled_context_menu"
    nonisolated static let servicesMenuKey = "enabled_services_menu"
    nonisolated static let presentationModesKey = "presentation_modes"
    nonisolated private static let flushPath = "/System/Library/CoreServices/pbs"

    /// Whether Finder shows the item. False until someone turns it on, which is
    /// what macOS does with an app's service it has not been told about.
    @Published private(set) var isEnabled = false
    /// True while a change is being written and the cache flushed.
    @Published private(set) var isApplying = false
    /// True when the last write went through but the Services cache could not
    /// be flushed, so Finder keeps the old state until the next login. The
    /// preference itself is saved either way.
    @Published private(set) var flushFailed = false

    private let defaults: UserDefaults
    private let statusKey: String
    private let flush: () async -> Bool

    init(defaults: UserDefaults, statusKey: String, flush: @escaping () async -> Bool) {
        self.defaults = defaults
        self.statusKey = statusKey
        self.flush = flush
        refresh()
    }

    /// How pbs names one service's entry: `<bundle id> - <menu title> - <message>`.
    nonisolated static func statusKey(bundleID: String) -> String {
        "\(bundleID) - \(FinderUninstallService.menuTitle) - \(FinderUninstallService.message)"
    }

    /// Reads the entry's context-menu flag. No entry means macOS's default for
    /// an app service, which is off.
    nonisolated static func isEnabled(in status: [String: Any]?, key: String) -> Bool {
        guard let entry = status?[key] as? [String: Any] else { return false }
        return (entry[contextMenuKey] as? Bool) ?? false
    }

    func refresh() {
        isEnabled = Self.isEnabled(in: defaults.dictionary(forKey: Self.statusDictionaryKey), key: statusKey)
    }

    /// Writes the entry System Settings would, keeping every other service's
    /// entry as it was, then flushes the Services cache and reads back.
    func setEnabled(_ enabled: Bool) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        var status = defaults.dictionary(forKey: Self.statusDictionaryKey) ?? [:]
        status[statusKey] = Self.entry(enabled: enabled)
        defaults.set(status, forKey: Self.statusDictionaryKey)
        // Both menus, the same as the tick in System Settings. Shown
        // optimistically so the switch does not snap back during the flush.
        isEnabled = enabled
        flushFailed = !(await flush())
        refresh()
    }

    nonisolated static func entry(enabled: Bool) -> [String: Any] {
        [
            contextMenuKey: enabled,
            servicesMenuKey: enabled,
            presentationModesKey: ["ContextMenu": true, "ServicesMenu": true],
        ]
    }

    /// `pbs -flush` drops the agent's cache so Finder rebuilds its menu from the
    /// preferences on the next right-click. `NSUpdateDynamicServices()` rescans
    /// providers but leaves that cache alone, so it is not enough here.
    /// False when pbs is missing, fails, or overruns its budget.
    private static func flushServicesCache() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: flushPath) else { return false }
        let output = await ProcessRunner.runAsync(executablePath: flushPath, arguments: ["-flush"], timeout: 5)
        return output?.succeeded ?? false
    }
}
