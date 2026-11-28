import Combine
import Foundation
import SwiftUI
import Testing
@testable import Purge

/// #457: with hundreds of apps, every store change redrew every row of the
/// uninstaller. Rows now read their own state, and one view serves their
/// right-click menus. These check that each piece only touches what changed.
@MainActor
@Suite("Uninstaller rows update one at a time")
struct UninstallRenderCostTests {
    private func value(_ name: String, bytes: Int64 = 1_000, selected: Bool = false) -> AppRowValue {
        AppRowValue(
            app: InstalledApp(
                name: name,
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                bundleID: "com.example.\(name)",
                bundleSizeBytes: bytes,
                isRunning: false
            ),
            size: AppRowSize(bytes: bytes, isPending: false, isFromLastScan: false),
            activityLabel: nil,
            isSelected: selected,
            isFromLastScan: false
        )
    }

    @Test
    func applyingTheSameValuesPublishesNothing() {
        let states = AppRowStates()
        let values = ["a": value("A"), "b": value("B")]
        states.apply(values)
        var published = 0
        let watchers = ["a", "b"].map { id in
            states.state(for: id).objectWillChange.sink { published += 1 }
        }
        states.apply(values)
        #expect(published == 0)
        _ = watchers
    }

    @Test
    func aTickPublishesForThatRowOnly() {
        let states = AppRowStates()
        states.apply(["a": value("A"), "b": value("B")])
        var publishedA = 0
        var publishedB = 0
        let watchA = states.state(for: "a").objectWillChange.sink { publishedA += 1 }
        let watchB = states.state(for: "b").objectWillChange.sink { publishedB += 1 }

        states.apply(["a": value("A", selected: true), "b": value("B")])

        #expect(publishedA == 1)
        #expect(publishedB == 0)
        #expect(states.state(for: "a").value.isSelected)
        #expect(!states.state(for: "b").value.isSelected)
        _ = (watchA, watchB)
    }

    @Test
    func aNewSizeReachesItsRow() {
        let states = AppRowStates()
        states.apply(["a": value("A", bytes: 1_000)])
        let row = states.state(for: "a")
        states.apply(["a": value("A", bytes: 5_000)])
        #expect(row.value.size.bytes == 5_000)
        #expect(states.state(for: "a") === row)
    }

    @Test
    func theSharedMenuFindsTheRowUnderThePoint() {
        let center = ScanRowMenuCenter()
        var activeA = false
        var activeB = false
        center.register("a", isMenuActive: Binding(get: { activeA }, set: { activeA = $0 })) {
            [.action(title: "A", handler: {})]
        }
        center.register("b", isMenuActive: Binding(get: { activeB }, set: { activeB = $0 })) {
            [.action(title: "B", handler: {})]
        }
        center.setFrame(CGRect(x: 0, y: 0, width: 100, height: 40), for: "a")
        center.setFrame(CGRect(x: 0, y: 50, width: 100, height: 40), for: "b")

        let menuB = center.menu(at: CGPoint(x: 10, y: 60))
        if case .action(let title, _) = menuB?.entries().first {
            #expect(title == "B")
        } else {
            Issue.record("Expected row B's menu")
        }
        menuB?.isMenuActive.wrappedValue = true
        #expect(activeB)
        #expect(!activeA)

        // The gap between rows belongs to no row, so the click is not claimed.
        #expect(center.menu(at: CGPoint(x: 10, y: 45)) == nil)
    }

    @Test
    func aRemovedRowHasNoMenu() {
        let center = ScanRowMenuCenter()
        center.register("a", isMenuActive: .constant(false)) { [.separator] }
        center.setFrame(CGRect(x: 0, y: 0, width: 100, height: 40), for: "a")
        #expect(center.menu(at: CGPoint(x: 5, y: 5)) != nil)
        center.remove("a")
        #expect(center.menu(at: CGPoint(x: 5, y: 5)) == nil)
    }

    @Test
    func aRowWithAFrameButNoMenuIsNotClaimed() {
        let center = ScanRowMenuCenter()
        center.setFrame(CGRect(x: 0, y: 0, width: 100, height: 40), for: "a")
        #expect(center.menu(at: CGPoint(x: 5, y: 5)) == nil)
    }
}
