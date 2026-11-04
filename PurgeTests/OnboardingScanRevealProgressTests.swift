import Foundation
import Testing
@testable import Purge

/// The first scan's bar sat at 100% while the scan was still running. It went to
/// the share of found rows already shown, and the reveal catches up with the
/// scan after its first row (#183).
@Suite("Onboarding scan progress")
struct OnboardingScanRevealProgressTests {
    @Test func oneRevealedRowDoesNotFillTheBar() {
        #expect(OnboardingScanRevealController.progress(afterRevealingFrom: 0) < 0.5)
    }

    @Test func theBarRisesWithEveryRowAndStaysBelowItsCeiling() {
        var progress = 0.0
        for row in 0..<500 {
            let next = OnboardingScanRevealController.progress(afterRevealingFrom: progress)
            // Later steps get too small for a Double to tell apart.
            #expect(row < 100 ? next > progress : next >= progress)
            progress = next
        }
        #expect(progress <= OnboardingScanRevealController.runningProgressCeiling)
        #expect(OnboardingScanRevealController.runningProgressCeiling < 1)
    }
}
