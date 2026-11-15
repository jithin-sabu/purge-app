import AppKit

/// A key the scan lists answer (#96), read from a key-down event.
///
/// Only plain keys and ⌘ combinations count. With Shift, Option or Control held
/// the key is left alone, so system and menu shortcuts keep working.
nonisolated enum ScanListKey: Equatable {
    case up, down, left, right
    /// Space: Quick Look the highlighted row, or close the preview.
    case space
    /// Return or X: tick or untick the highlighted row.
    case toggle
    /// ⌘⌫: open the row's confirm sheet.
    case trash
    /// ⌘C: copy the row's path.
    case copy
    /// ⌘↓ and ⌘↑: open and close a group, as Finder opens a folder and goes to
    /// the one that holds it.
    case openGroup, closeGroup

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        /// ANSI positions of X and C, for layouts whose letters aren't Latin.
        static let x: UInt16 = 7
        static let c: UInt16 = 8
    }

    init?(keyCode: UInt16, charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) {
        // Arrow keys always carry .function and .numericPad, and Caps Lock says
        // nothing about intent, so none of the three count as a modifier here.
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let letter = Self.latinLetter(charactersIgnoringModifiers)

        switch flags {
        case []:
            switch keyCode {
            case KeyCode.up: self = .up
            case KeyCode.down: self = .down
            case KeyCode.left: self = .left
            case KeyCode.right: self = .right
            case KeyCode.space: self = .space
            case KeyCode.returnKey, KeyCode.keypadEnter: self = .toggle
            default:
                guard Self.matches(letter, "x", keyCode: keyCode, ansi: KeyCode.x) else { return nil }
                self = .toggle
            }
        case [.command]:
            switch keyCode {
            case KeyCode.delete: self = .trash
            case KeyCode.down: self = .openGroup
            case KeyCode.up: self = .closeGroup
            default:
                guard Self.matches(letter, "c", keyCode: keyCode, ansi: KeyCode.c) else { return nil }
                self = .copy
            }
        default:
            return nil
        }
    }

    /// The typed character when it is a Latin letter, lowercased, else nil.
    private static func latinLetter(_ characters: String?) -> Character? {
        guard let characters, characters.count == 1, let character = characters.lowercased().first,
              character.isASCII, character.isLetter
        else { return nil }
        return character
    }

    /// A Latin layout matches by the letter it types, wherever the key sits
    /// (Dvorak, AZERTY). Any other layout, such as Russian, matches by the ANSI
    /// key position, which is where ⌘C sits on those layouts too.
    private static func matches(_ letter: Character?, _ wanted: Character, keyCode: UInt16, ansi: UInt16) -> Bool {
        if let letter { return letter == wanted }
        return keyCode == ansi
    }
}
