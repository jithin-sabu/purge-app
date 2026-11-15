import Foundation
import Testing
@testable import Purge

/// The per-app header checkbox in the uninstall review sheet. A catalog dot
/// folder (#228) starts unticked and holds settings, extensions and history, so
/// the header must never tick it: one click on a plan whose only unticked row is
/// that folder clears the list, as it did before #228, instead of ticking the
/// folder along with the rest. Clearing is the safer direction, so the header
/// does clear a dot folder the user ticked.
@Suite("Uninstall review header checkbox never ticks a catalog dot folder")
struct UninstallHeaderCheckboxTests {
    private let checkFirst = SafetyInfo(
        level: .medium,
        headline: "",
        explanation: "",
        recoverySteps: "",
        reinstallCommand: nil
    )

    private let trae = InstalledApp(
        name: "Trae",
        bundleURL: URL(fileURLWithPath: "/Applications/Trae.app", isDirectory: true),
        bundleID: "com.trae.app",
        bundleSizeBytes: 0,
        isRunning: false
    )

    private func item(
        _ path: String,
        category: UninstallCategory,
        selected: Bool,
        keptFor: String? = nil
    ) -> UninstallItem {
        var item = UninstallItem(
            path: URL(fileURLWithPath: path),
            sizeBytes: 100,
            category: category,
            safetyInfo: checkFirst,
            matchReason: category == .bundle ? .appBundle : .bundleID,
            isSelected: selected
        )
        item.keptForApp = keptFor
        return item
    }

    private func plan(dotFolderSelected: Bool, othersSelected: Bool) -> UninstallAppPlan {
        UninstallAppPlan(app: trae, items: [
            item("/Applications/Trae.app", category: .bundle, selected: othersSelected),
            item("/Users/x/Library/Preferences/com.trae.app.plist", category: .preferences, selected: othersSelected),
            item("/Users/x/.trae", category: .homeFolderData, selected: dotFolderSelected),
        ])
    }

    /// A scripts folder with files in it (#352) is opt-in the same way: the
    /// header never ticks it, reads "all" without it, and can still clear it.
    @Test
    func scriptsFolderWithFilesIsNotTickedByTheHeader() {
        var scripts = item("/Users/x/Library/Application Scripts/com.trae.app", category: .applicationScripts, selected: false)
        scripts.holdsAddedScripts = true
        var plan = UninstallAppPlan(app: trae, items: [
            item("/Applications/Trae.app", category: .bundle, selected: true),
            item("/Users/x/Library/Application Scripts/TEAM123456.com.trae.app", category: .applicationScripts, selected: true),
            scripts,
        ])
        #expect(!plan.items[2].isTickedByHeader)
        // An empty scripts folder is an ordinary row.
        #expect(plan.items[1].isTickedByHeader)
        #expect(plan.headerSelection == .all)

        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan).isEmpty)
        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan) == ["Trae.app", "TEAM123456.com.trae.app"])

        // Ticked on its own row, it survives ticking the rest and goes with clearing.
        plan.items[0].isSelected = false
        plan.items[2].isSelected = true
        plan.toggleAllFromHeader()
        #expect(plan.items[2].isSelected)
        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan).isEmpty)
    }

    private func selectedPaths(_ plan: UninstallAppPlan) -> [String] {
        plan.selectedItems.map(\.path.lastPathComponent)
    }

    @Test
    func catalogDotFolderIsNotTickedByTheHeader() {
        let plan = plan(dotFolderSelected: false, othersSelected: true)
        #expect(!plan.items[2].isTickedByHeader)
        #expect(plan.items[0].isTickedByHeader)
        #expect(plan.items[1].isTickedByHeader)
    }

    /// The scan's starting state: every row ticked but the dot folder. The
    /// header reads "all", not "mixed", so one click clears the list.
    @Test
    func startingStateReadsAllAndOneClickClearsTheList() {
        var plan = plan(dotFolderSelected: false, othersSelected: true)
        #expect(plan.headerSelection == .all)
        plan.toggleAllFromHeader()
        #expect(plan.headerSelection == .none)
        #expect(selectedPaths(plan).isEmpty)
    }

    @Test
    func tickingAllFromAnEmptyListLeavesTheDotFolderUnticked() {
        var plan = plan(dotFolderSelected: false, othersSelected: false)
        #expect(plan.headerSelection == .none)
        plan.toggleAllFromHeader()
        #expect(plan.headerSelection == .all)
        #expect(selectedPaths(plan) == ["Trae.app", "com.trae.app.plist"])
    }

    @Test
    func mixedListTicksTheRestAndLeavesTheDotFolderUnticked() {
        var plan = plan(dotFolderSelected: false, othersSelected: false)
        plan.items[0].isSelected = true
        #expect(plan.headerSelection == .mixed)
        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan) == ["Trae.app", "com.trae.app.plist"])
    }

    /// The user ticked the dot folder on its own row. Ticking the rest from the
    /// header keeps that choice; clearing from the header clears it too.
    @Test
    func aDotFolderTheUserTickedSurvivesTickingAndGoesWithClearing() {
        var plan = plan(dotFolderSelected: true, othersSelected: false)
        #expect(plan.headerSelection == .none)
        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan) == ["Trae.app", "com.trae.app.plist", ".trae"])
        #expect(plan.headerSelection == .all)
        plan.toggleAllFromHeader()
        #expect(selectedPaths(plan).isEmpty)
    }

    /// A row kept for a surviving app is locked off in both directions.
    @Test
    func keptRowIsNeverTouched() {
        var plan = plan(dotFolderSelected: false, othersSelected: false)
        plan.items.append(item(
            "/Users/x/Library/Application Support/Trae", category: .applicationSupport,
            selected: false, keptFor: "Trae 2"
        ))
        plan.toggleAllFromHeader()
        #expect(!plan.items[3].isSelected)
        #expect(plan.headerSelection == .all)
        plan.items[3].isSelected = true
        plan.toggleAllFromHeader()
        #expect(plan.items[3].isSelected)
        #expect(selectedPaths(plan) == ["Trae"])
    }
}
