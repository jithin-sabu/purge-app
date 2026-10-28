import Foundation

/// The size line beside a removal sheet's buttons. A move to the Trash frees
/// nothing until the Trash is emptied, so only what is deleted permanently is
/// called freed (#191).
enum RemovalSizeLine {
    /// Each total is `nil` when nothing in the sheet goes that way.
    static func text(toTrash trashBytes: Int64?, permanently permanentBytes: Int64? = nil) -> String {
        switch (trashBytes, permanentBytes) {
        case let (trash?, permanent?):
            return String(localized: "Moving \(formatBytes(trash)) to Trash, freeing \(formatBytes(permanent))")
        case let (nil, permanent?):
            return String(localized: "Freeing \(formatBytes(permanent))")
        case let (trash?, nil):
            return String(localized: "Moving \(formatBytes(trash)) to Trash")
        case (nil, nil):
            return String(localized: "Moving \(formatBytes(0)) to Trash")
        }
    }

    /// Sums the sizes, or `nil` for an empty list.
    static func total<Item>(_ items: [Item], _ size: (Item) -> Int64) -> Int64? {
        items.isEmpty ? nil : items.reduce(Int64(0)) { $0 + size($1) }
    }
}
