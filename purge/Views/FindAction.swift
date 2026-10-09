import AppKit
import SwiftUI

/// What Edit > Find (⌘F) does on the tab that is showing. A search field publishes
/// one with `.focusedSceneValue(\.findAction, ...)` for as long as it is on screen,
/// so the menu item greys out by itself on tabs without a field, while a tab is
/// locked behind Full Disk Access, and while the window is closed.
struct FindAction {
    let perform: () -> Void

    func callAsFunction() { perform() }

    /// Selects whatever the focused field holds so typing replaces the old search.
    /// Runs on the next turn of the run loop because the focus change has to reach
    /// AppKit before the field editor is the first responder.
    static func selectAllInFieldEditor() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }
}

private struct FindActionKey: FocusedValueKey {
    typealias Value = FindAction
}

extension FocusedValues {
    var findAction: FindAction? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
}
