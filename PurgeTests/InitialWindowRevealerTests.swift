import Foundation
import Testing
@testable import Purge

@Suite("InitialWindowRevealer retries only for a window that lost the front")
struct InitialWindowRevealerTests {

    /// The retries exist for a launch window another app pushed back. A window
    /// the user closed or minimised within those seconds must stay that way:
    /// SwiftUI keeps it in `NSApp.windows`, so revealing would bring it back.
    @Test(
        "A retry needs an inactive app and a window that is not closed or minimised",
        arguments: [
            (false, true, true),
            (false, false, false),
            (false, nil, true),
            (true, true, false),
            (true, false, false),
            (true, nil, false),
        ] as [(Bool, Bool?, Bool)]
    )
    func retryDecision(appIsActive: Bool, windowIsOpen: Bool?, expected: Bool) {
        #expect(
            InitialWindowRevealer.shouldRevealAgain(
                appIsActive: appIsActive,
                windowIsOpen: windowIsOpen
            ) == expected
        )
    }
}
