import Foundation
import Testing
@testable import Purge

@Suite("TimeTagline time formatting")
struct TimeTaglineTimeTextTests {
    @Test(arguments: [
        (0.84, "0.8 seconds"),
        (0.04, "0.1 seconds"),
        (0.0, "0.1 seconds"),
        (1.0, "1 second"),
        (1.4, "1 second"),
        (2.4, "2 seconds"),
        (59.0, "59 seconds"),
        (59.8, "1m 0s"),
        (61.0, "1m 1s"),
        (134.0, "2m 14s"),
    ])
    func formatsElapsedTime(seconds: Double, expected: String) {
        #expect(TimeTagline.timeText(for: seconds) == expected)
    }
}
