import AppKit
import Foundation
import Testing
@testable import Purge

/// Purge's resize delegate takes the window's delegate from SwiftUI. It passed
/// on only the two calls it handles, so every other call SwiftUI's delegate
/// answers was lost (#183).
@MainActor
@Suite("The fixed-width window delegate passes calls on")
struct FixedWindowWidthDelegateTests {
    private final class SpyDelegate: NSObject, NSWindowDelegate {
        var becameKey = 0
        func windowDidBecomeKey(_ notification: Notification) { becameKey += 1 }
    }

    @Test func aCallItDoesNotHandleReachesTheDelegateItTookOver() {
        let spy = SpyDelegate()
        let delegate = FixedWindowWidthDelegate(fixedWidth: 980, minHeight: 600, chainedDelegate: spy)
        let selector = #selector(NSWindowDelegate.windowDidBecomeKey(_:))

        #expect(delegate.responds(to: selector))
        (delegate as NSWindowDelegate).windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(spy.becameKey == 1)
    }

    @Test func itAnswersNothingTheOtherDelegateDoesNot() {
        let delegate = FixedWindowWidthDelegate(fixedWidth: 980, minHeight: 600, chainedDelegate: SpyDelegate())
        #expect(!delegate.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
        // Its own calls stay its own.
        #expect(delegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))))
    }
}
