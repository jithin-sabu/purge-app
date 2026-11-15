import Foundation

/// The keyboard highlight of a scan list (#96): which row is current, and where
/// it goes when a key moves it or the list changes under it.
///
/// The highlight is not the selection. Moving it never ticks anything, and
/// ticking only moves it to the row that was clicked.
///
/// A list is laid out as rows of items. A plain list has one item per row; the
/// Uninstaller's grid has up to four, and a group's open tray adds rows of its
/// own, so rows can differ in length.
nonisolated enum ScanListHighlight {
    enum Direction: Equatable {
        case up, down, left, right
    }

    /// Where `direction` takes the highlight from `current`.
    ///
    /// Up and down keep the column, or take the row's last item when the row is
    /// shorter. Left and right step through the items in reading order. At an
    /// edge the highlight stays where it is.
    ///
    /// With nothing highlighted, or a highlight the list no longer shows, the
    /// first key takes `firstVisible`, the first row on screen, so the list
    /// never jumps to a row the user can't see. Without one, down and right
    /// start at the top and up and left at the bottom.
    static func moved<ID: Hashable>(
        from current: ID?,
        _ direction: Direction,
        in rows: [[ID]],
        firstVisible: ID? = nil
    ) -> ID? {
        let rows = rows.filter { !$0.isEmpty }
        guard let first = rows.first?.first, let last = rows.last?.last else { return nil }

        guard let current, let (row, column) = position(of: current, in: rows) else {
            if let firstVisible, position(of: firstVisible, in: rows) != nil { return firstVisible }
            switch direction {
            case .down, .right: return first
            case .up, .left: return last
            }
        }

        switch direction {
        case .up:
            guard row > 0 else { return current }
            let above = rows[row - 1]
            return above[min(column, above.count - 1)]
        case .down:
            guard row < rows.count - 1 else { return current }
            let below = rows[row + 1]
            return below[min(column, below.count - 1)]
        case .left, .right:
            let flat = rows.flatMap { $0 }
            guard let index = flat.firstIndex(of: current) else { return current }
            let next = direction == .left ? index - 1 : index + 1
            return flat.indices.contains(next) ? flat[next] : current
        }
    }

    /// Where the highlight goes when the list's order changes: a filter, a
    /// search, a scan that finished, rows that were trashed, a group that closed.
    ///
    /// - A row still shown keeps the highlight.
    /// - A row that left the list for good (`stillExists` is false), as after a
    ///   trash, hands it to the next row that is still shown, or else the one
    ///   before, as Finder does.
    /// - A row hidden inside a group that closed hands it to the group.
    /// - Anything else, like a row a filter or search hides, clears it.
    static func reconciled<ID: Hashable>(
        _ current: ID?,
        oldOrder: [ID],
        newOrder: [ID],
        stillExists: (ID) -> Bool,
        parent: (ID) -> ID? = { _ in nil }
    ) -> ID? {
        guard let current else { return nil }
        let shown = Set(newOrder)
        if shown.contains(current) { return current }

        if !stillExists(current), let index = oldOrder.firstIndex(of: current) {
            if let after = oldOrder[(index + 1)...].first(where: shown.contains) { return after }
            if let before = oldOrder[..<index].last(where: shown.contains) { return before }
            return nil
        }

        if let parent = parent(current), shown.contains(parent) { return parent }
        return nil
    }

    private static func position<ID: Hashable>(of id: ID, in rows: [[ID]]) -> (row: Int, column: Int)? {
        for (row, items) in rows.enumerated() {
            if let column = items.firstIndex(of: id) { return (row, column) }
        }
        return nil
    }
}
