import Foundation
import Testing
@testable import Purge

@Suite("Select All never sweeps in Check First rows by itself")
@MainActor
struct SafeFirstSelectAllTests {
    private typealias Model = SafeFirstSelectAll<String>

    private func entry(_ key: String, safe: Bool, selected: Bool = false, bytes: Int64 = 100) -> Model.Entry {
        Model.Entry(key: key, isSafe: safe, isSelected: selected, bytes: bytes)
    }

    @Test func onAllTheCheckboxSelectsOnlySafeRows() {
        let model = Model(
            entries: [entry("a", safe: true), entry("b", safe: false), entry("c", safe: true)],
            filter: .all
        )
        #expect(model.title == "Select All Safe")
        #expect(model.isEnabled)
        #expect(model.toggled() == Model.Change(select: ["a", "c"]))
        #expect(model.checkFirstLink == nil)
    }

    @Test func theLinkAppearsOnceEverySafeRowIsSelected() throws {
        let model = Model(
            entries: [
                entry("a", safe: true, selected: true),
                entry("b", safe: false, bytes: 1_500_000_000),
                entry("c", safe: false, bytes: 500_000_000),
            ],
            filter: .all
        )
        #expect(model.state == .mixed)
        let link = try #require(model.checkFirstLink)
        #expect(link.title == "Also select 2 Check First items (\(formatBytes(2_000_000_000)))")
        #expect(link.change == Model.Change(select: ["b", "c"]))
    }

    @Test func theLinkCountsOnlyUnselectedCheckFirstRows() throws {
        let model = Model(
            entries: [
                entry("a", safe: true, selected: true),
                entry("b", safe: false, selected: true),
                entry("c", safe: false),
            ],
            filter: .all
        )
        let link = try #require(model.checkFirstLink)
        #expect(link.title.hasPrefix("Also select 1 Check First item ("))
        #expect(link.change == Model.Change(select: ["c"]))
    }

    @Test func withEverythingSelectedTheCheckboxClearsTheList() {
        let model = Model(
            entries: [entry("a", safe: true, selected: true), entry("b", safe: false, selected: true)],
            filter: .all
        )
        #expect(model.state == .all)
        #expect(model.title == "Select All")
        #expect(model.checkFirstLink == nil)
        #expect(model.toggled() == Model.Change(deselect: ["a", "b"]))
    }

    @Test func withOnlySafeRowsSelectedTheCheckboxClearsThem() {
        let model = Model(
            entries: [entry("a", safe: true, selected: true), entry("b", safe: false)],
            filter: .all
        )
        #expect(model.toggled() == Model.Change(deselect: ["a"]))
    }

    @Test func aHandPickedCheckFirstRowStaysWhenSafeRowsAreAdded() {
        let model = Model(
            entries: [entry("a", safe: true), entry("b", safe: false, selected: true)],
            filter: .all
        )
        #expect(model.toggled() == Model.Change(select: ["a"]))
    }

    @Test func onlyCheckFirstRowsOnAllNeedTheLink() throws {
        let model = Model(entries: [entry("b", safe: false), entry("c", safe: false)], filter: .all)
        #expect(!model.isEnabled)
        let link = try #require(model.checkFirstLink)
        #expect(link.title.hasPrefix("Select 2 Check First items ("))
    }

    @Test func theCheckFirstFilterSelectsEveryRow() {
        let model = Model(entries: [entry("b", safe: false), entry("c", safe: false)], filter: .checkFirst)
        #expect(model.title == "Select All")
        #expect(model.isEnabled)
        #expect(model.toggled() == Model.Change(select: ["b", "c"]))
        #expect(model.checkFirstLink == nil)
    }

    @Test func anAllSafeListBehavesLikeAPlainSelectAll() {
        let model = Model(entries: [entry("a", safe: true), entry("c", safe: true, selected: true)], filter: .all)
        #expect(model.title == "Select All")
        #expect(model.toggled() == Model.Change(select: ["a"]))
        #expect(model.checkFirstLink == nil)
    }

    @Test func anEmptyListIsDisabled() {
        #expect(!Model(entries: [], filter: .all).isEnabled)
        #expect(!Model(entries: [], filter: .safe).isEnabled)
    }
}
