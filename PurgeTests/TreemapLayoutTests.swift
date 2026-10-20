import CoreGraphics
import Foundation
import Testing
@testable import Purge

/// The map's layout (#220): the squarify step, the 3 px cut, the smaller tile,
/// and stability when one size changes.
@Suite("Treemap layout")
struct TreemapLayoutTests {
    private let rect = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func items(_ weights: [Double]) -> [TreemapItem] {
        weights.enumerated().map { TreemapItem(id: "item-\($0.offset)", weight: $0.element) }
    }

    // MARK: Squarify

    @Test func tilesCoverTheRectInProportionAndNeverOverlap() {
        let tiles = TreemapLayout.squarify(items([6, 6, 4, 3, 2, 2, 1]), in: rect)
        #expect(tiles.count == 7)
        let total = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(total - 240_000) < 1)
        for tile in tiles {
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect), "\(tile.id) leaves the rect")
            let share = Double(tile.rect.width * tile.rect.height) / 240_000
            #expect(abs(share - tile.weight / 24) < 0.0001, "\(tile.id) has the wrong area")
        }
        for (index, first) in tiles.enumerated() {
            for second in tiles[(index + 1)...] {
                #expect(!first.rect.insetBy(dx: 0.01, dy: 0.01).intersects(second.rect), "\(first.id) overlaps \(second.id)")
            }
        }
    }

    @Test func equalWeightsComeOutSquare() {
        let tiles = TreemapLayout.squarify(items([1, 1, 1, 1]), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for tile in tiles {
            #expect(abs(tile.rect.width - 200) < 0.01)
            #expect(abs(tile.rect.height - 200) < 0.01)
        }
    }

    @Test func theSquarifyStepPrefersTheRowWithTheBetterAspect() {
        // Bruls' worked example: 6, 6, 4, 3, 2, 2, 1 in a 6 by 4 box. The first row
        // holds 6 and 6 as two 3 by 2 tiles (aspect 1.5); adding 4 would make it worse.
        let box = CGRect(x: 0, y: 0, width: 6, height: 4)
        let scale = 1.0
        let two = TreemapLayout.worstAspect(items([6, 6]), side: 4, scale: scale)
        let three = TreemapLayout.worstAspect(items([6, 6, 4]), side: 4, scale: scale)
        #expect(abs(two - 1.5) < 0.0001)
        #expect(three > two)
        let tiles = TreemapLayout.squarify(items([6, 6, 4, 3, 2, 2, 1]), in: box)
        #expect(tiles[0].rect == CGRect(x: 0, y: 0, width: 3, height: 2))
        #expect(tiles[1].rect == CGRect(x: 0, y: 2, width: 3, height: 2))
        // The worst aspect ratio across the whole layout stays modest.
        let worst = tiles.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        #expect(worst <= 3)
    }

    @Test func zeroWeightsAndAnEmptyRectGiveNoTiles() {
        #expect(TreemapLayout.squarify(items([0, 0]), in: rect).isEmpty)
        #expect(TreemapLayout.squarify(items([1, 2]), in: .zero).isEmpty)
    }

    // MARK: The 3 px cut

    @Test func tilesThinnerThanThreePointsAreNotDrawn() {
        // One item so small its tile would be well under 3 pt wide.
        let plan = TreemapLayout.plan(items([1000, 0.1]), in: rect, floorWeight: 0)
        #expect(plan.tiles.map(\.id) == ["item-0"])
        #expect(plan.hiddenCount == 1)
        #expect(plan.smallerCount == 0)
    }

    // MARK: The smaller tile

    @Test func everythingUnderTheFloorBecomesOneTileThatIsNeverHidden() {
        let plan = TreemapLayout.plan(items([500, 300, 0.4, 0.3, 0.2]), in: rect, floorWeight: 1)
        #expect(plan.smallerCount == 3)
        #expect(abs(plan.smallerWeight - 0.9) < 0.0001)
        let smaller = plan.tiles.first { $0.id == TreemapPlan.smallerID }
        #expect(smaller != nil)
        #expect(smaller.map { $0.rect.width < TreemapLayout.minimumTileSide || $0.rect.height < TreemapLayout.minimumTileSide } == true)
        #expect(plan.hiddenCount == 0)
        #expect(plan.tiles.map(\.id) == ["item-0", "item-1", TreemapPlan.smallerID])
    }

    @Test func noSmallerTileWhenNothingIsUnderTheFloor() {
        let plan = TreemapLayout.plan(items([5, 4]), in: rect, floorWeight: 1)
        #expect(plan.smallerCount == 0)
        #expect(!plan.tiles.contains { $0.id == TreemapPlan.smallerID })
    }

    // MARK: Stability

    @Test func aSizeChangeResizesWithoutReshuffling() {
        let first = TreemapLayout.plan(items([50, 40, 30, 20, 10]), in: rect, floorWeight: 1)
        #expect(first.order == ["item-0", "item-1", "item-2", "item-3", "item-4"])

        // The third item grows past the first. Biggest-first would move it to the
        // front; with the previous order it stays where it was and only grows.
        let grown = [
            TreemapItem(id: "item-0", weight: 50),
            TreemapItem(id: "item-1", weight: 40),
            TreemapItem(id: "item-2", weight: 90),
            TreemapItem(id: "item-3", weight: 20),
            TreemapItem(id: "item-4", weight: 10)
        ]
        let second = TreemapLayout.plan(grown, in: rect, floorWeight: 1, previousOrder: first.order)
        #expect(second.order == first.order)
        #expect(second.tiles.map(\.id) == first.tiles.map(\.id))
        let before = first.tiles.first { $0.id == "item-2" }!.rect
        let after = second.tiles.first { $0.id == "item-2" }!.rect
        #expect(after.width * after.height > before.width * before.height)

        // Without the previous order it would have been reshuffled.
        let fresh = TreemapLayout.plan(grown, in: rect, floorWeight: 1)
        #expect(fresh.order.first == "item-2")
    }

    @Test func newItemsJoinAfterTheKnownOnesBySize() {
        let first = TreemapLayout.plan(items([50, 40]), in: rect, floorWeight: 1)
        let next = [
            TreemapItem(id: "item-1", weight: 40),
            TreemapItem(id: "new-small", weight: 5),
            TreemapItem(id: "item-0", weight: 50),
            TreemapItem(id: "new-big", weight: 60)
        ]
        let second = TreemapLayout.plan(next, in: rect, floorWeight: 1, previousOrder: first.order)
        #expect(second.order == ["item-0", "item-1", "new-big", "new-small"])
    }
}
