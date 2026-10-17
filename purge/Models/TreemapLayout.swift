import CoreGraphics
import Foundation

/// One thing to place on the map, by weight (bytes).
nonisolated struct TreemapItem: Equatable, Sendable {
    let id: String
    let weight: Double

    init(id: String, weight: Double) {
        self.id = id
        self.weight = max(0, weight)
    }
}

/// Where one item landed.
nonisolated struct TreemapTile: Equatable, Identifiable, Sendable {
    let id: String
    let rect: CGRect
    let weight: Double
}

/// A level of the map laid out: the tiles to draw and what was rolled up or cut.
nonisolated struct TreemapPlan: Equatable, Sendable {
    /// The id of the one tile that stands for everything under the floor.
    static let smallerID = "treemap.smaller"

    let tiles: [TreemapTile]
    /// How many items went into the smaller tile.
    let smallerCount: Int
    let smallerWeight: Double
    /// Items laid out but too thin to draw. Their area stays blank.
    let hiddenCount: Int
    /// The ids in the order they were laid out, to hand back next time so a
    /// re-measure resizes the tiles without reshuffling them.
    let order: [String]
}

/// A squarified treemap (Bruls, Huizing and van Wijk) in pure Swift (#220).
///
/// Items are laid out in the order given, so the caller decides between
/// biggest-first and keeping an earlier order. `plan` does the rest the map
/// needs: it rolls everything under a floor into one "smaller" tile that is
/// never hidden, and drops tiles thinner than `minimumTileSide`, the "pixel
/// mush" QDirStat and DaisyDisk both cut.
nonisolated enum TreemapLayout {
    /// Tiles under this on either side are not drawn.
    static let minimumTileSide: CGFloat = 3

    /// Lays out `items` by weight in `rect`, in the order given. Zero-weight
    /// items get no tile.
    static func squarify(_ items: [TreemapItem], in rect: CGRect) -> [TreemapTile] {
        let items = items.filter { $0.weight > 0 }
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total

        var tiles: [TreemapTile] = []
        var remaining = rect
        var row: [TreemapItem] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            let side = Double(min(remaining.width, remaining.height))
            let current = worstAspect(row, side: side, scale: scale)
            let extended = worstAspect(row + [item], side: side, scale: scale)
            if row.isEmpty || extended <= current {
                row.append(item)
                index += 1
            } else {
                remaining = layoutRow(row, in: remaining, scale: scale, into: &tiles)
                row = []
            }
        }
        if !row.isEmpty {
            _ = layoutRow(row, in: remaining, scale: scale, into: &tiles)
        }
        return tiles
    }

    /// The worst aspect ratio of a row laid along a side of length `side`.
    /// Infinite for an empty row, so any first item improves on it.
    static func worstAspect(_ row: [TreemapItem], side: Double, scale: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let areas = row.map { $0.weight * scale }
        let sum = areas.reduce(0, +)
        guard sum > 0, let largest = areas.max(), let smallest = areas.min(), smallest > 0 else { return .infinity }
        let side2 = side * side
        return max(side2 * largest / (sum * sum), (sum * sum) / (side2 * smallest))
    }

    /// Places one row along the shorter side of `rect` and returns what is left.
    private static func layoutRow(_ row: [TreemapItem], in rect: CGRect, scale: Double, into tiles: inout [TreemapTile]) -> CGRect {
        let rowArea = row.reduce(0) { $0 + $1.weight * scale }
        let horizontal = rect.width >= rect.height
        // The row is a strip across the shorter side; its thickness comes from its area.
        let thickness = horizontal ? rowArea / Double(rect.height) : rowArea / Double(rect.width)
        var offset = 0.0
        for item in row {
            let area = item.weight * scale
            let length = thickness > 0 ? area / thickness : 0
            let tileRect: CGRect
            if horizontal {
                tileRect = CGRect(x: Double(rect.minX), y: Double(rect.minY) + offset, width: thickness, height: length)
            } else {
                tileRect = CGRect(x: Double(rect.minX) + offset, y: Double(rect.minY), width: length, height: thickness)
            }
            tiles.append(TreemapTile(id: item.id, rect: tileRect, weight: item.weight))
            offset += length
        }
        if horizontal {
            return CGRect(x: Double(rect.minX) + thickness, y: Double(rect.minY), width: Double(rect.width) - thickness, height: Double(rect.height))
        }
        return CGRect(x: Double(rect.minX), y: Double(rect.minY) + thickness, width: Double(rect.width), height: Double(rect.height) - thickness)
    }

    /// The map's layout for one level. Items under `floorWeight` roll into one
    /// smaller tile at the end. With `previousOrder`, ids seen before keep their
    /// place and new ones join by size, so a re-measure resizes without
    /// reshuffling; without it, biggest first.
    static func plan(
        _ items: [TreemapItem],
        in rect: CGRect,
        floorWeight: Double,
        previousOrder: [String]? = nil
    ) -> TreemapPlan {
        let live = items.filter { $0.weight > 0 }
        let big = live.filter { $0.weight >= floorWeight }
        let small = live.filter { $0.weight < floorWeight }
        let smallerWeight = small.reduce(0) { $0 + $1.weight }

        var ordered = big.sorted { $0.weight > $1.weight }
        if let previousOrder {
            let rank = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($1, $0) })
            let known = ordered.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            let fresh = ordered.filter { rank[$0.id] == nil }
            ordered = known + fresh
        }
        if smallerWeight > 0 {
            ordered.append(TreemapItem(id: TreemapPlan.smallerID, weight: smallerWeight))
        }

        let laid = squarify(ordered, in: rect)
        var tiles: [TreemapTile] = []
        var hidden = 0
        for tile in laid {
            // The smaller tile is never cut: it is the one place the long tail shows.
            if tile.id != TreemapPlan.smallerID, tile.rect.width < minimumTileSide || tile.rect.height < minimumTileSide {
                hidden += 1
                continue
            }
            tiles.append(tile)
        }
        return TreemapPlan(
            tiles: tiles,
            smallerCount: small.count,
            smallerWeight: smallerWeight,
            hiddenCount: hidden,
            order: ordered.map(\.id)
        )
    }
}
