import Foundation
import Testing
@testable import Purge

/// The counted phrases come from `en.lproj/Localizable.stringsdict` (#185). Each
/// key here is one the app looks up, read from the English table whatever the
/// Mac's language, so a missing or broken rule shows as "1 items".
@Suite("Plural phrases")
struct PluralPhraseTests {
    private let english = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? .main
    private let locale = Locale(identifier: "en")

    private func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: english, locale: locale)
    }

    @Test("One reads singular and other counts plural")
    func countsReadSingularAndPlural() {
        #expect(text("\(1) items") == "1 item")
        #expect(text("\(3) items") == "3 items")
        #expect(text("\(0) items") == "0 items")
        #expect(text("\(1) apps") == "1 app")
        #expect(text("\(2) tools") == "2 tools")
        #expect(text("\(1) other copies") == "1 other copy")
        #expect(text("\(1) items to trash") == "1 item to trash")
        #expect(text("\(1) other identical copies found") == "1 other identical copy found")
    }

    @Test("The count reads right beside other values")
    func countBesideOtherValues() {
        #expect(text("\(1) items · \("2 GB") recoverable") == "1 item · 2 GB recoverable")
        #expect(text("\(4) files · \("2 GB") to review") == "4 files · 2 GB to review")
        #expect(text("\(1) files over \("1 GB")") == "1 file over 1 GB")
        #expect(text("\(1) files over \("1 GB") not used in \("a year")") == "1 file over 1 GB not used in a year")
        #expect(text("\("Also select") \(1) Check First items (\("5 MB"))") == "Also select 1 Check First item (5 MB)")
        #expect(
            text("Moved \(1) items to Trash, about \("5 MB"). Empty the trash to reclaim the space.")
                == "Moved 1 item to Trash, about 5 MB. Empty the trash to reclaim the space."
        )
    }
}
