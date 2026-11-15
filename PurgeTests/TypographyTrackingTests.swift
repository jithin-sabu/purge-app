import SwiftUI
import Testing
@testable import Purge

/// Onest has no optical sizes, so each style carries the tracking its size
/// needs (#263). These checks keep the scale consistent when a value changes.
struct TypographyTrackingTests {
    private static let onestStyles: [AppStyle.TextStyle] = [
        AppStyle.Typography.iconLabel,
        AppStyle.Typography.micro,
        AppStyle.Typography.metadata,
        AppStyle.Typography.metadataEmphasis,
        AppStyle.Typography.callout,
        AppStyle.Typography.body,
        AppStyle.Typography.rowTitle,
        AppStyle.Typography.headline,
        AppStyle.Typography.sectionTitle,
        AppStyle.Typography.pageTitle,
        AppStyle.Typography.title,
    ]

    private static let roundedStyles: [AppStyle.TextStyle] = [
        AppStyle.Typography.display,
        AppStyle.Typography.displaySmall,
    ]

    @Test func trackingNeverGrowsWithSize() {
        let bySize = Self.onestStyles.sorted { $0.size < $1.size }
        for (smaller, larger) in zip(bySize, bySize.dropFirst()) {
            #expect(larger.tracking <= smaller.tracking, "\(larger.size)pt is tracked wider than \(smaller.size)pt")
        }
    }

    @Test func smallTextIsTrackedAndLargeTextIsNot() {
        for style in Self.onestStyles {
            if style.size < 20 {
                #expect(style.tracking > 0, "\(style.size)pt has no tracking")
            } else {
                #expect(style.tracking == 0, "\(style.size)pt is tracked")
            }
        }
    }

    @Test func systemFontsTakeNoTracking() {
        for style in Self.roundedStyles {
            #expect(style.family == .rounded)
            #expect(style.tracking == 0)
        }
        for style in Self.onestStyles {
            #expect(style.numbers.family == .rounded)
            #expect(style.numbers.tracking == 0)
            #expect(style.monospaced().family == .monospaced)
            #expect(style.monospaced().tracking == 0)
        }
    }

    @Test func emphasisKeepsSizeAndTracking() {
        let body = AppStyle.Typography.body
        let strong = body.weight(.semibold)
        #expect(strong.size == body.size)
        #expect(strong.tracking == body.tracking)
        #expect(strong.weight == .semibold)
        #expect(body.numbers.size == body.size)
        #expect(body.numbers.weight == body.weight)
    }
}
