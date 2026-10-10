import Foundation

/// What Select All does on the App Caches and Dev Tools tabs.
///
/// On the All filter the list mixes Safe and Check First rows. The checkbox selects
/// the safe rows only. Adding the Check First rows takes a second click, on a link
/// that says how many there are and how much they hold, so one click can never
/// sweep a Check First row into a clean. On the Safe and Check First filters the
/// list holds one kind, and Select All selects every row.
struct SafeFirstSelectAll<Key: Hashable> {
    struct Entry {
        let key: Key
        let isSafe: Bool
        let isSelected: Bool
        let bytes: Int64
    }

    /// The keys a click selects and clears.
    struct Change: Equatable {
        var select: [Key] = []
        var deselect: [Key] = []
    }

    let entries: [Entry]
    /// True on the All filter when the list has Check First rows.
    let isSafeFirst: Bool

    init(entries: [Entry], filter: SafetyFilter) {
        self.entries = entries
        isSafeFirst = filter == .all && entries.contains { !$0.isSafe }
    }

    private var safeEntries: [Entry] { entries.filter(\.isSafe) }
    private var unselectedCheckFirst: [Entry] { entries.filter { !$0.isSafe && !$0.isSelected } }

    var state: SelectAllTriState {
        let selected = entries.count(where: \.isSelected)
        if selected == 0 { return .none }
        return selected == entries.count ? .all : .mixed
    }

    var title: String {
        isSafeFirst && state != .all ? String(localized: "Select All Safe") : String(localized: "Select All")
    }

    /// Off when a click could do nothing: an empty list, or a list with only Check
    /// First rows on the All filter and nothing selected yet.
    var isEnabled: Bool {
        guard !entries.isEmpty else { return false }
        if isSafeFirst, safeEntries.isEmpty { return state != .none }
        return true
    }

    /// A click on the checkbox. On the All filter it selects the safe rows, and once
    /// they are all selected it clears the list. Elsewhere it selects every row, and
    /// clears them once they are all selected.
    func toggled() -> Change {
        if isSafeFirst {
            if safeEntries.allSatisfy(\.isSelected) {
                return Change(deselect: entries.filter(\.isSelected).map(\.key))
            }
            return Change(select: safeEntries.filter { !$0.isSelected }.map(\.key))
        }
        if state == .all {
            return Change(deselect: entries.map(\.key))
        }
        return Change(select: entries.filter { !$0.isSelected }.map(\.key))
    }

    /// The link that adds the Check First rows. It shows on the All filter once every
    /// safe row is selected, while some Check First row is not.
    var checkFirstLink: (title: String, change: Change)? {
        guard isSafeFirst, safeEntries.allSatisfy(\.isSelected) else { return nil }
        let rows = unselectedCheckFirst
        guard !rows.isEmpty else { return nil }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.bytes }
        let noun = rows.count == 1 ? String(localized: "item") : String(localized: "items")
        let verb = safeEntries.isEmpty ? String(localized: "Select") : String(localized: "Also select")
        return (
            String(localized: "\(verb) \(rows.count) Check First \(noun) (\(formatBytes(bytes)))"),
            Change(select: rows.map(\.key))
        )
    }
}
