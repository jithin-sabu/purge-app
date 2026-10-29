import Foundation
import Testing
@testable import Purge

/// Many tests compare English text and sizes written as "1.2 GB". The purge scheme's
/// test action pins the test host to English and the US region (`language` and
/// `region` on its TestAction), so those tests pass on a Mac set to Chinese, or to
/// a region that writes "1,2 GB" (#189). If the pin is lost, these fail too, and
/// say why.
@Suite("The test host runs in English")
struct TestHostLanguageTests {
    @Test func appTextIsEnglish() {
        #expect(
            String(localized: "Retry") == "Retry",
            "The host is not in English. Run the tests with the purge scheme, which sets the test language to English."
        )
    }

    @Test func numbersAreWrittenTheUSWay() {
        #expect(
            Locale.current.decimalSeparator == ".",
            "The host is not in the US region. Run the tests with the purge scheme, which sets the test region to the US."
        )
    }
}
