import Foundation

/// How Dev Tools shows the Xcode build folder rows (#480): one card that
/// opens in place, holding the folders whose source folder is gone and the
/// folders whose source folder is still on this Mac as two parts, each with
/// its own checkbox. Display only: every folder stays its own Dev Tools
/// row, picked and cleaned like any other, so nothing here reaches a
/// deletion gate.
struct XcodeBuildFolderGroup: Equatable {
    enum Part: Hashable, CaseIterable {
        /// The folder holding the project file it was built from is gone. The
        /// project itself may still be here, in another checkout.
        case projectGone
        /// The project is still here, or Purge may not look.
        case projectHere
    }

    struct Member: Equatable {
        /// The Dev Tools row's id.
        let id: String
        let bytes: Int64
        let isSelected: Bool
        let part: Part
    }

    /// What a click ticks and clears, by row id.
    struct Change: Equatable {
        var select: [String] = []
        var deselect: [String] = []
    }

    /// In the list's order.
    let members: [Member]

    /// Nil when there is nothing to show.
    init?(members: [Member]) {
        guard !members.isEmpty else { return nil }
        self.members = members
    }

    /// The parts that hold a folder, gone first.
    var parts: [Part] {
        Part.allCases.filter { !members(in: $0).isEmpty }
    }

    func members(in part: Part) -> [Member] {
        members.filter { $0.part == part }
    }

    var bytes: Int64 { members.reduce(0) { $0 + $1.bytes } }

    func bytes(in part: Part) -> Int64 {
        members(in: part).reduce(0) { $0 + $1.bytes }
    }

    var state: SelectAllTriState { Self.state(of: members) }

    func state(in part: Part) -> SelectAllTriState { Self.state(of: members(in: part)) }

    /// The card's checkbox: ticks every folder, or clears them all once all
    /// are ticked.
    func toggled() -> Change { Self.toggle(members) }

    /// A part's checkbox, the same way for its folders alone.
    func toggled(part: Part) -> Change { Self.toggle(members(in: part)) }

    private static func state(of members: [Member]) -> SelectAllTriState {
        let selected = members.count(where: \.isSelected)
        if selected == 0 { return .none }
        return selected == members.count ? .all : .mixed
    }

    private static func toggle(_ members: [Member]) -> Change {
        if !members.isEmpty, members.allSatisfy(\.isSelected) {
            return Change(deselect: members.map(\.id))
        }
        return Change(select: members.filter { !$0.isSelected }.map(\.id))
    }
}
