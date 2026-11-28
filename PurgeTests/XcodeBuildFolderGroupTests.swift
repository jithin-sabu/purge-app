import Foundation
import Testing
@testable import Purge

/// The Xcode build folders card in Dev Tools (#480): its parts, the state of
/// each checkbox, and what a click ticks.
@Suite("Xcode build folders card")
struct XcodeBuildFolderGroupTests {
    private typealias Group = XcodeBuildFolderGroup

    private func member(
        _ id: String, _ part: Group.Part, selected: Bool = false, bytes: Int64 = 100
    ) -> Group.Member {
        Group.Member(id: id, bytes: bytes, isSelected: selected, part: part)
    }

    @Test("no folders, no card")
    func emptyIsNil() {
        #expect(Group(members: []) == nil)
    }

    @Test("parts hold their folders, gone first, and empty parts are left out")
    func partsSplitByProject() throws {
        let group = try #require(Group(members: [
            member("a", .projectHere, bytes: 300),
            member("b", .projectGone, bytes: 200),
            member("c", .projectHere, bytes: 100),
        ]))
        #expect(group.parts == [.projectGone, .projectHere])
        #expect(group.members(in: .projectGone).map(\.id) == ["b"])
        #expect(group.members(in: .projectHere).map(\.id) == ["a", "c"])
        #expect(group.bytes == 600)
        #expect(group.bytes(in: .projectHere) == 400)

        let onlyHere = try #require(Group(members: [member("a", .projectHere)]))
        #expect(onlyHere.parts == [.projectHere])
    }

    @Test("the card's checkbox reads every folder, a part's only its own")
    func triStates() throws {
        let group = try #require(Group(members: [
            member("gone1", .projectGone, selected: true),
            member("gone2", .projectGone, selected: true),
            member("here", .projectHere),
        ]))
        #expect(group.state == .mixed)
        #expect(group.state(in: .projectGone) == .all)
        #expect(group.state(in: .projectHere) == .none)
    }

    @Test("a part's checkbox ticks only that part, and clears it once all are ticked")
    func partToggleStaysInPart() throws {
        let none = try #require(Group(members: [
            member("gone1", .projectGone),
            member("gone2", .projectGone, selected: true),
            member("here", .projectHere),
        ]))
        #expect(none.toggled(part: .projectGone) == Group.Change(select: ["gone1"]))

        let all = try #require(Group(members: [
            member("gone1", .projectGone, selected: true),
            member("here", .projectHere),
        ]))
        #expect(all.toggled(part: .projectGone) == Group.Change(deselect: ["gone1"]))
    }

    @Test("the card's checkbox ticks every folder, then clears them all")
    func cardToggle() throws {
        let mixed = try #require(Group(members: [
            member("gone", .projectGone, selected: true),
            member("here", .projectHere),
        ]))
        #expect(mixed.toggled() == Group.Change(select: ["here"]))

        let all = try #require(Group(members: [
            member("gone", .projectGone, selected: true),
            member("here", .projectHere, selected: true),
        ]))
        #expect(all.toggled() == Group.Change(deselect: ["gone", "here"]))
    }
}
