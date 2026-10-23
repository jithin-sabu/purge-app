import AppKit
import CoreText
import SwiftUI

enum AppStyle {
    /// Corner radii. Action buttons and chips are capsules, so they take no
    /// radius token.
    enum Radius {
        /// Badges, progress bars, skeleton bars, small icon tiles.
        static let xs: CGFloat = 4
        /// Chips inside a field, dropdown rows, thumbnails.
        static let sm: CGFloat = 6
        /// Controls that hold a value: pickers, fields, segmented controls.
        static let md: CGFloat = 8
        /// Cards, list rows, sheets, notices.
        static let lg: CGFloat = 14
        /// Panels floating on the cleanup celebration.
        static let xl: CGFloat = 18
    }

    enum IconTile {
        static let size: CGFloat = 28
        /// Matches the outline of the bundled Apple Intelligence mark. Keep the
        /// radius proportional so the continuous curve scales with the tile.
        static let cornerRadiusRatio: CGFloat = 0.26

        static func shape(size: CGFloat = size) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: size * cornerRadiusRatio, style: .continuous)
        }
    }

    enum Control {
        /// Shared height for inline pill controls (menu pickers, small text
        /// fields) so they line up when placed side by side.
        static let height: CGFloat = 28
    }

    enum Spacing {
        static let xxSmall: CGFloat = 4
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    enum Row {
        static let compactHeight: CGFloat = 36
        static let parentHeight: CGFloat = 44
        static let listRowMinHeight: CGFloat = 52
        /// Scan row leading icon frame (brand PNGs and SF Symbol fallbacks).
        static let listIconFrameSize: CGFloat = 28
        /// Point size for SF Symbol row icons (e.g. simulator host, folder fallback).
        static let sfSymbolPointSize: CGFloat = 18
        /// Project group headers (node_modules, Flutter, etc.) — slightly smaller than scan rows (28pt).
        static let projectGroupIconSize: CGFloat = 16
        /// Aligns expanded artifact text with the project title (parent checkbox + spacing).
        static let projectArtifactLeadingInset: CGFloat = 34
        /// Inner horizontal padding for scan result cards (matches `ScanResultRow` chrome).
        static let scanCardHorizontalPadding: CGFloat = 14
    }

    /// One step of the type scale: family, size, weight, and the tracking
    /// (letter spacing, in points) that goes with the size. Onest has no
    /// optical sizes, so small text gets a little air and large text none.
    /// SF Rounded spaces itself at every size, so it takes no tracking (#263).
    struct TextStyle: Hashable {
        enum Family: Hashable {
            case onest
            case rounded
            case monospaced
        }

        let family: Family
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat

        var font: Font {
            switch family {
            case .onest: AppFonts.onest(size: size, weight: weight)
            case .rounded: .system(size: size, weight: weight, design: .rounded)
            case .monospaced: .system(size: size, weight: weight, design: .monospaced)
            }
        }

        /// The same style at another weight, for emphasis.
        func weight(_ weight: Font.Weight) -> TextStyle {
            TextStyle(family: family, size: size, weight: weight, tracking: tracking)
        }

        /// SF Rounded at this style's size and weight, for sizes, units and
        /// percentages. System styles, such as `display`, come back unchanged.
        var numbers: TextStyle {
            TextStyle(family: .rounded, size: size, weight: weight, tracking: 0)
        }

        /// The system monospaced font at this style's size and weight, for
        /// paths and commands. Fixed-width glyphs carry their own space.
        func monospaced() -> TextStyle {
            TextStyle(family: .monospaced, size: size, weight: weight, tracking: 0)
        }
    }

    /// The type scale. Every `.font(...)` on text picks one of these, adding
    /// `.weight(...)` when it needs emphasis; no view sets a point size or
    /// tracking of its own. SF Rounded is kept for result numbers.
    enum Typography {
        /// Freed bytes on the cleanup celebration.
        static let display = TextStyle(family: .rounded, size: 56, weight: .bold, tracking: 0)
        /// Large totals: Overview, onboarding results.
        static let displaySmall = TextStyle(family: .rounded, size: 36, weight: .bold, tracking: 0)
        /// Onboarding and empty-state headings.
        static let title = onest(26, .semibold, tracking: 0)
        static let pageTitle = onest(20, .semibold, tracking: 0)
        /// Sheet titles, card headers, large buttons.
        static let sectionTitle = onest(15, .semibold, tracking: 0.1)
        /// Group headers, emphasis, regular buttons.
        static let headline = onest(13, .semibold, tracking: 0.15)
        static let body = onest(13, tracking: 0.15)
        /// List row titles, menu rows.
        static let rowTitle = onest(13, .medium, tracking: 0.15)
        /// Helper text under controls, small buttons.
        static let callout = onest(12, tracking: 0.25)
        /// Sizes, dates, paths.
        static let metadata = onest(11, tracking: 0.3)
        static let metadataEmphasis = onest(11, .medium, tracking: 0.3)
        /// Badges and count pills.
        static let micro = onest(10, .semibold, tracking: 0.4)
        /// File-type labels laid over a 28pt icon, where `micro` is too wide.
        static let iconLabel = onest(8, .semibold, tracking: 0.45)

        private static func onest(_ size: CGFloat, _ weight: Font.Weight = .regular, tracking: CGFloat) -> TextStyle {
            TextStyle(family: .onest, size: size, weight: weight, tracking: tracking)
        }
    }
}

extension View {
    /// Sets a type-scale style: its font and its tracking.
    func font(_ style: AppStyle.TextStyle) -> some View {
        self.font(style.font).tracking(style.tracking)
    }
}

extension Text {
    /// Sets a type-scale style: its font and its tracking.
    func font(_ style: AppStyle.TextStyle) -> Text {
        self.font(style.font).tracking(style.tracking)
    }

    /// `string` in `style`, with each figure and its unit, such as "4.71 GB",
    /// "110" or "5 MB", in SF Rounded, so a sentence built around a number
    /// shows it like the figures elsewhere on the page.
    init(figures string: String, style: AppStyle.TextStyle) {
        // A separator counts only between digits, so "Removed 3, but" keeps its comma in Onest.
        let figure = #/[0-9](?:[.,]?[0-9])*(?:\s?(?:[KMGT]?B|%))?/#
        var text = Text(verbatim: "")
        var index = string.startIndex
        for match in string.matches(of: figure) {
            text = text + Text(verbatim: String(string[index..<match.range.lowerBound])).font(style)
            text = text + Text(verbatim: String(match.output)).font(style.numbers)
            index = match.range.upperBound
        }
        self = text + Text(verbatim: String(string[index...])).font(style)
    }
}

extension View {
    /// Shared style for explanatory helper text in Settings, so caption styling
    /// can never drift between sections.
    func settingsCaption() -> some View {
        self.font(AppStyle.Typography.callout)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Hairline separator inset from card edges (matches card content horizontal padding).
struct InsetCardDivider: View {
    var horizontalInset: CGFloat = AppStyle.Spacing.medium

    var body: some View {
        Rectangle()
            .fill(AppColors.borderSubtle)
            .frame(height: 0.5)
            .padding(.horizontal, horizontalInset)
    }
}

/// Onest for text, SF Rounded for figures.
///
/// `Resources/Fonts/OnestText.ttf` is Onest (SIL Open Font License, see
/// `Onest-OFL.txt`) with its ten digits removed, so a digit inside ordinary text
/// falls back to the system font. It is registered for this process, which lets
/// SwiftUI's own `.weight(_:)` drive the variable weight axis. Text that shows
/// sizes, units or percentages uses `TextStyle.numbers` instead.
enum AppFonts {
    private static let isRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "OnestText", withExtension: "ttf") else { return false }
        var error: Unmanaged<CFError>?
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()

    static func onest(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Without the font file, fall back to the system font, not a missing face.
        isRegistered
            ? Font.custom("Onest", size: size).weight(weight)
            : Font.system(size: size, weight: weight)
    }
}
