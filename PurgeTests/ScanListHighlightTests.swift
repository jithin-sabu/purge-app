import AppKit
import Foundation
import Testing
@testable import Purge

/// The keyboard highlight in the scan lists (#96): how the keys move it, and
/// where it lands when the list changes under it.
@Suite("Scan list highlight moves like Finder's")
struct ScanListHighlightTests {
    private let flat = [["a"], ["b"], ["c"]]

    // MARK: - Moving

    @Test
    func downAndUpStepThroughAList() {
        #expect(ScanListHighlight.moved(from: "a", .down, in: flat) == "b")
        #expect(ScanListHighlight.moved(from: "b", .up, in: flat) == "a")
    }

    @Test
    func theEdgesHoldTheHighlight() {
        #expect(ScanListHighlight.moved(from: "a", .up, in: flat) == "a")
        #expect(ScanListHighlight.moved(from: "c", .down, in: flat) == "c")
        #expect(ScanListHighlight.moved(from: "a", .left, in: flat) == "a")
        #expect(ScanListHighlight.moved(from: "c", .right, in: flat) == "c")
    }

    /// The first key lands on the first row on screen, not on a row scrolled away.
    @Test
    func theFirstKeyTakesTheFirstRowOnScreen() {
        #expect(ScanListHighlight.moved(from: nil, .down, in: flat, firstVisible: "b") == "b")
        #expect(ScanListHighlight.moved(from: nil, .up, in: flat, firstVisible: "b") == "b")
    }

    @Test
    func withNoRowOnScreenKnownDownStartsAtTheTopAndUpAtTheBottom() {
        #expect(ScanListHighlight.moved(from: nil, .down, in: flat) == "a")
        #expect(ScanListHighlight.moved(from: nil, .up, in: flat) == "c")
        #expect(ScanListHighlight.moved(from: nil, .down, in: flat, firstVisible: "gone") == "a")
    }

    /// A highlight the list no longer shows counts as none.
    @Test
    func aHighlightTheListLostStartsOver() {
        #expect(ScanListHighlight.moved(from: "gone", .down, in: flat, firstVisible: "c") == "c")
    }

    @Test
    func anEmptyListHasNoHighlight() {
        #expect(ScanListHighlight.moved(from: "a", .down, in: [[String]]()) == nil)
        #expect(ScanListHighlight.moved(from: nil, .down, in: [[String](), []]) == nil)
    }

    // MARK: - The grid

    /// Four apps to a row, the last row short.
    private let grid = [["a", "b", "c", "d"], ["e", "f", "g", "h"], ["i", "j"]]

    @Test
    func upAndDownKeepTheColumn() {
        #expect(ScanListHighlight.moved(from: "b", .down, in: grid) == "f")
        #expect(ScanListHighlight.moved(from: "j", .up, in: grid) == "f")
    }

    @Test
    func aShortRowTakesItsLastItem() {
        #expect(ScanListHighlight.moved(from: "h", .down, in: grid) == "j")
    }

    @Test
    func leftAndRightWrapAcrossRows() {
        #expect(ScanListHighlight.moved(from: "d", .right, in: grid) == "e")
        #expect(ScanListHighlight.moved(from: "e", .left, in: grid) == "d")
    }

    /// An open group's tray sits between grid rows as rows of its own.
    @Test
    func trayRowsAreRowsLikeAnyOther() {
        let withTray = [["a", "group", "c", "d"], ["m1", "m2"], ["e", "f", "g", "h"]]
        #expect(ScanListHighlight.moved(from: "group", .down, in: withTray) == "m2")
        #expect(ScanListHighlight.moved(from: "m2", .down, in: withTray) == "f")
        #expect(ScanListHighlight.moved(from: "g", .up, in: withTray) == "m2")
    }

    // MARK: - When the list changes

    @Test
    func aRowStillShownKeepsTheHighlight() {
        let result = ScanListHighlight.reconciled(
            "b", oldOrder: ["a", "b", "c"], newOrder: ["c", "b"], stillExists: { _ in true }
        )
        #expect(result == "b")
    }

    /// After a trash the next row takes over, as in Finder.
    @Test
    func aTrashedRowHandsTheHighlightToTheNextRow() {
        let result = ScanListHighlight.reconciled(
            "b", oldOrder: ["a", "b", "c"], newOrder: ["a", "c"], stillExists: { $0 != "b" }
        )
        #expect(result == "c")
    }

    @Test
    func theLastRowTrashedHandsItBack() {
        let result = ScanListHighlight.reconciled(
            "c", oldOrder: ["a", "b", "c"], newOrder: ["a", "b"], stillExists: { $0 != "c" }
        )
        #expect(result == "b")
    }

    @Test
    func theOnlyRowTrashedClearsIt() {
        let result = ScanListHighlight.reconciled(
            "a", oldOrder: ["a"], newOrder: [], stillExists: { _ in false }
        )
        #expect(result == nil)
    }

    /// A filter or search that hides the row does not move the highlight onto
    /// some other row the user didn't pick.
    @Test
    func aRowAFilterHidesClearsIt() {
        let result = ScanListHighlight.reconciled(
            "b", oldOrder: ["a", "b", "c"], newOrder: ["a", "c"], stillExists: { _ in true }
        )
        #expect(result == nil)
    }

    @Test
    func aRowInAGroupThatClosedHandsItToTheGroup() {
        let result = ScanListHighlight.reconciled(
            "member",
            oldOrder: ["group", "member", "next"],
            newOrder: ["group", "next"],
            stillExists: { _ in true },
            parent: { $0 == "member" ? "group" : nil }
        )
        #expect(result == "group")
    }

    @Test
    func nothingHighlightedStaysThatWay() {
        let result = ScanListHighlight.reconciled(
            nil, oldOrder: ["a"], newOrder: ["a"], stillExists: { _ in true }
        )
        #expect(result == nil)
    }
}

/// Reading the scan list keys from key-down events (#96).
@Suite("Scan list keys")
struct ScanListKeyTests {
    private func key(_ code: UInt16, _ characters: String? = nil, _ flags: NSEvent.ModifierFlags = []) -> ScanListKey? {
        ScanListKey(keyCode: code, charactersIgnoringModifiers: characters, modifierFlags: flags)
    }

    /// Arrow keys always arrive with .function and .numericPad set.
    @Test
    func arrowsCountDespiteTheirOwnFlags() {
        let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(key(126, nil, arrowFlags) == .up)
        #expect(key(125, nil, arrowFlags) == .down)
        #expect(key(123, nil, arrowFlags) == .left)
        #expect(key(124, nil, arrowFlags) == .right)
    }

    @Test
    func spaceReturnEnterAndXAnswer() {
        #expect(key(49, " ") == .space)
        #expect(key(36, "\r") == .toggle)
        #expect(key(76, "\u{3}", .numericPad) == .toggle)
        #expect(key(7, "x") == .toggle)
        #expect(key(7, "X", .capsLock) == .toggle)
    }

    @Test
    func commandKeys() {
        #expect(key(51, "\u{7f}", .command) == .trash)
        #expect(key(8, "c", .command) == .copy)
        #expect(key(125, nil, [.command, .function, .numericPad]) == .openGroup)
        #expect(key(126, nil, [.command, .function, .numericPad]) == .closeGroup)
    }

    /// Delete without ⌘ does nothing: the list never trashes on a bare key.
    @Test
    func plainDeleteIsLeftAlone() {
        #expect(key(51, "\u{7f}") == nil)
    }

    @Test
    func otherModifiersLeaveTheKeyAlone() {
        #expect(key(126, nil, [.shift, .function, .numericPad]) == nil)
        #expect(key(8, "c", [.command, .shift]) == nil)
        #expect(key(51, "\u{7f}", [.command, .option]) == nil)
        #expect(key(49, " ", .control) == nil)
        #expect(key(7, "x", .command) == nil)
    }

    /// Dvorak puts X and C on other keys; the letter typed is what counts.
    @Test
    func latinLayoutsMatchByLetter() {
        #expect(key(11, "x") == .toggle)
        #expect(key(34, "c", .command) == .copy)
        // On Dvorak the ANSI C key types J, which is not Copy.
        #expect(key(8, "j", .command) == nil)
    }

    /// Russian types Cyrillic letters, so the ANSI key position is used.
    @Test
    func nonLatinLayoutsMatchByKeyPosition() {
        #expect(key(7, "ч") == .toggle)
        #expect(key(8, "с", .command) == .copy)
        #expect(key(9, "м", .command) == nil)
    }

    @Test
    func otherKeysAreLeftAlone() {
        #expect(key(0, "a") == nil)
        #expect(key(53, "\u{1b}") == nil)
        #expect(key(48, "\t") == nil)
    }
}
