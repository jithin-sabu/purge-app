import Testing
@testable import Purge

/// ⌘1 … ⌘5 switch tabs from the View menu, so the safety filters had to move to
/// ⌥⌘1 … ⌥⌘3. The menu numbers tabs by their place in `keyboardTabs`.
@MainActor
@Suite("Tab shortcuts follow the sidebar")
struct TabShortcutTests {

    @Test("⌘1 … ⌘5 go down the sidebar, Overview first")
    func keyboardTabsMatchSidebarOrder() {
        #expect(PurgeStore.Tab.keyboardTabs == [.overview, .appCaches, .devTools, .largeFiles, .uninstaller])
    }

    @Test("Settings and About get no number")
    func utilityTabsAreLeftOut() {
        for tab in PurgeStore.Tab.utilityTabs {
            #expect(!PurgeStore.Tab.keyboardTabs.contains(tab))
        }
    }

    @Test("Filter tooltips name the Option-Command keys")
    func filterTooltipsShowOptionCommand() {
        #expect(SafetyFilter.all.tooltipHint() == "Show all items (⌥⌘1)")
        #expect(SafetyFilter.safe.tooltipHint() == "Show safe items (⌥⌘2)")
        #expect(SafetyFilter.checkFirst.tooltipHint() == "Show check-first items (⌥⌘3)")
    }
}
