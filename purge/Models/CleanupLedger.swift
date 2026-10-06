import Foundation

/// Which part of Purge a clean came from. Stored with every ledger session so a
/// year's totals can be split by feature later.
enum CleanupSource: String, Codable, Hashable, CaseIterable {
    /// Caches, logs and developer rows: Clean Safe Items, a scheduled clean, or a
    /// hand-picked selection on the scan tabs.
    case clean
    case largeFiles
    /// Leftovers from apps that are already gone (orphan scan and removed-app review).
    case leftovers
    /// Apps removed with the uninstaller, plus the leftovers removed with them.
    case uninstall
    /// A failed item retried from the cleanup overlay.
    case retry
}

/// One item a clean removed. `path` is home-relative (`~/Library/Caches/Dia`), so
/// the ledger never stores the account name.
struct CleanupLedgerItem: Codable, Hashable {
    let path: String
    let bytes: Int64
    /// The name Purge showed for the item, or one derived from the path when no
    /// row name was known. Always filled at record time, because a bundle ID can
    /// only be turned into an app name while that app is still installed.
    let label: String
    /// `false` for items removed outright rather than trashed (simulators).
    let movedToTrash: Bool
}

/// One clean, appended as a single JSON line to that year's ledger file.
///
/// Unlike `cleanup_history.json`, which keeps the last 100 cleans for the History
/// screen, the ledger is never trimmed. It is the full record a year-end recap
/// reads from.
struct CleanupLedgerSession: Codable, Identifiable, Hashable {
    /// Matches the `CleanupHistoryEntry` id when the clean also went to history,
    /// which is what makes importing that history safe to repeat.
    let id: UUID
    let date: Date
    let trigger: CleanupTrigger
    let source: CleanupSource
    let bytesMovedToTrash: Int64
    let bytesRemovedDirectly: Int64
    /// Measured volume delta, only when it cleared measurement noise. Same rule as
    /// history: `nil` is unknown and must never be filled in with moved bytes.
    let bytesReclaimedOnVolume: Int64?
    let skippedForSafetyCount: Int
    let failedCount: Int
    /// `true` for sessions copied from `cleanup_history.json` when the ledger was
    /// introduced. Those carry no row names or failure counts, and their source is
    /// inferred, so a recap can say "since <date>" instead of "this year".
    let importedFromHistory: Bool
    let items: [CleanupLedgerItem]

    var bytesCleared: Int64 { bytesMovedToTrash + bytesRemovedDirectly }
}

// MARK: - Labels

enum CleanupLedgerLabel {
    /// Library folders whose next path component names the owning app.
    private static let ownerRoots: Set<String> = [
        "Caches", "Application Support", "Containers", "Group Containers", "Logs",
        "HTTPStorages", "WebKit", "Saved Application State", "Preferences",
        "Developer", "Cookies", "Application Scripts",
    ]

    /// Home dot-folders that only hold other tools' folders (`~/.cache/huggingface`).
    private static let sharedDotFolders: Set<String> = [".cache", ".config", ".local"]

    /// A best-effort owner name for a home-relative path, for cleans where Purge
    /// had no row name (imported history). `resolveBundleID` maps a bundle ID to an
    /// installed app's name.
    static func derive(fromPath path: String, resolveBundleID: (String) -> String?) -> String {
        var components = path.split(separator: "/").map(String.init)
        if components.first == "~" { components.removeFirst() }
        guard let first = components.first else { return path }

        if let bundle = components.first(where: isAppBundleName) {
            return String(bundle.dropLast(4))
        }

        if first == "Library", components.count >= 3, ownerRoots.contains(components[1]) {
            return ownerName(components[2], resolveBundleID: resolveBundleID)
        }

        if first.hasPrefix("."), first.count > 1 {
            if sharedDotFolders.contains(first), components.count >= 2 {
                return components[1]
            }
            return String(first.dropFirst())
        }

        return components.last ?? path
    }

    /// Whether a path is an application bundle. A folder named after a bundle ID
    /// can also end in `.app` (`~/Library/Caches/io.getpurge.app`), so a name
    /// shaped like a bundle ID does not count.
    static func isAppBundle(path: String) -> Bool {
        path.split(separator: "/").last.map { isAppBundleName(String($0)) } ?? false
    }

    private static func isAppBundleName(_ name: String) -> Bool {
        name.hasSuffix(".app") && name.count > 4 && !looksLikeBundleID(name)
    }

    /// Turns a folder named after a bundle ID into the app's name when it can.
    /// Group containers carry a team prefix (`6N38VWS5BX.ru.keepcoder.Telegram`)
    /// or `group.`, which are stripped first.
    static func ownerName(_ folder: String, resolveBundleID: (String) -> String?) -> String {
        var candidate = folder
        if candidate.hasPrefix("group.") {
            candidate = String(candidate.dropFirst("group.".count))
        }
        if let dot = candidate.firstIndex(of: "."), isTeamIdentifier(candidate[..<dot]) {
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        guard looksLikeBundleID(candidate) else { return folder }
        if let name = resolveBundleID(candidate) { return name }
        // An app that is no longer installed: its bundle ID's last meaningful part
        // is still closer to a name than the reverse-DNS string. `io.getpurge.app`
        // should read "getpurge", not "app".
        let parts = candidate.split(separator: ".").map(String.init)
        return parts.last { !genericBundleSuffixes.contains($0.lowercased()) } ?? folder
    }

    private static let genericBundleSuffixes: Set<String> = ["app", "mac", "macos", "osx", "desktop"]

    private static func isTeamIdentifier(_ text: Substring) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && !text.contains(" ") && parts.allSatisfy { !$0.isEmpty }
    }
}

// MARK: - Year totals

/// What a year of cleaning adds up to. Computed from the ledger on demand, never
/// stored, so new questions can be asked of old data.
struct CleanupYearTotals: Equatable {
    struct LabelTotal: Equatable {
        let label: String
        var bytes: Int64
        var itemCount: Int
    }

    struct BiggestItem: Equatable {
        let label: String
        let path: String
        let bytes: Int64
        let date: Date
    }

    struct BiggestClean: Equatable {
        let date: Date
        let bytes: Int64
    }

    let year: Int
    /// The first clean on record for the year. When imported history is the
    /// oldest data, this is where the record starts, not January 1.
    var firstRecordedDate: Date?
    var includesImportedHistory = false
    var cleanCount = 0
    var manualCleanCount = 0
    var scheduledCleanCount = 0
    /// Distinct calendar days with at least one clean.
    var activeDayCount = 0
    var itemCount = 0
    var bytesMovedToTrash: Int64 = 0
    var bytesRemovedDirectly: Int64 = 0
    /// Sum of measured volume deltas only. Usually far below moved bytes, because
    /// a move to the Trash frees nothing until the Trash is emptied.
    var bytesReclaimedOnVolume: Int64 = 0
    var skippedForSafetyCount = 0
    var bytesBySource: [CleanupSource: Int64] = [:]
    /// Index 0 is January.
    var bytesByMonth: [Int64] = Array(repeating: 0, count: 12)
    /// Every label, largest first.
    var labels: [LabelTotal] = []
    var biggestItem: BiggestItem?
    var biggestClean: BiggestClean?
    /// Apps removed with the uninstaller, in the order they were removed.
    var uninstalledApps: [String] = []

    var bytesCleared: Int64 { bytesMovedToTrash + bytesRemovedDirectly }

    static func compute(
        year: Int,
        sessions: [CleanupLedgerSession],
        calendar: Calendar = .current
    ) -> CleanupYearTotals {
        var totals = CleanupYearTotals(year: year)
        var days = Set<DateComponents>()
        var labelIndex: [String: Int] = [:]
        var seenApps = Set<String>()

        let ordered = sessions
            .filter { calendar.component(.year, from: $0.date) == year }
            .sorted { $0.date < $1.date }

        for session in ordered {
            totals.firstRecordedDate = totals.firstRecordedDate ?? session.date
            totals.includesImportedHistory = totals.includesImportedHistory || session.importedFromHistory
            totals.cleanCount += 1
            switch session.trigger {
            case .manual: totals.manualCleanCount += 1
            case .scheduled: totals.scheduledCleanCount += 1
            }
            days.insert(calendar.dateComponents([.year, .month, .day], from: session.date))

            totals.bytesMovedToTrash += session.bytesMovedToTrash
            totals.bytesRemovedDirectly += session.bytesRemovedDirectly
            totals.bytesReclaimedOnVolume += max(0, session.bytesReclaimedOnVolume ?? 0)
            totals.skippedForSafetyCount += session.skippedForSafetyCount
            totals.bytesBySource[session.source, default: 0] += session.bytesCleared
            let month = calendar.component(.month, from: session.date) - 1
            if totals.bytesByMonth.indices.contains(month) {
                totals.bytesByMonth[month] += session.bytesCleared
            }
            if session.bytesCleared > (totals.biggestClean?.bytes ?? 0) {
                totals.biggestClean = BiggestClean(date: session.date, bytes: session.bytesCleared)
            }

            for item in session.items {
                totals.itemCount += 1
                if let index = labelIndex[item.label] {
                    totals.labels[index].bytes += item.bytes
                    totals.labels[index].itemCount += 1
                } else {
                    labelIndex[item.label] = totals.labels.count
                    totals.labels.append(LabelTotal(label: item.label, bytes: item.bytes, itemCount: 1))
                }
                if item.bytes > (totals.biggestItem?.bytes ?? 0) {
                    totals.biggestItem = BiggestItem(
                        label: item.label, path: item.path, bytes: item.bytes, date: session.date
                    )
                }
                if session.source == .uninstall, CleanupLedgerLabel.isAppBundle(path: item.path),
                   seenApps.insert(item.label).inserted {
                    totals.uninstalledApps.append(item.label)
                }
            }
        }

        totals.activeDayCount = days.count
        totals.labels.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.label < $1.label }
        return totals
    }
}
