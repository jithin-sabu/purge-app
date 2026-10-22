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

    /// The type scale. Every `.font(...)` on text picks one of these, adding
    /// `.weight(...)` when it needs emphasis; no view sets a point size of its
    /// own. SF Rounded is kept for result numbers and page titles.
    enum Typography {
        /// Freed bytes on the cleanup celebration.
        static let display = Font.system(size: 56, weight: .bold, design: .rounded)
        /// Large totals: Overview, onboarding results.
        static let displaySmall = Font.system(size: 36, weight: .bold, design: .rounded)
        /// Onboarding and empty-state headings.
        static let title = AppFonts.onest(size: 26, weight: .semibold)
        static let pageTitle = AppFonts.onest(size: 20, weight: .semibold)
        /// Sheet titles, card headers, large buttons.
        static let sectionTitle = AppFonts.onest(size: 15, weight: .semibold)
        /// Group headers, emphasis, regular buttons.
        static let headline = AppFonts.onest(size: 13, weight: .semibold)
        static let body = AppFonts.onest(size: 13)
        /// List row titles, menu rows.
        static let rowTitle = AppFonts.onest(size: 13, weight: .medium)
        /// Helper text under controls, small buttons.
        static let callout = AppFonts.onest(size: 12)
        /// Sizes, dates, paths.
        static let metadata = AppFonts.onest(size: 11)
        static let metadataEmphasis = AppFonts.onest(size: 11, weight: .medium)
        /// Badges and count pills.
        static let micro = AppFonts.onest(size: 10, weight: .semibold)
        /// File-type labels laid over a 28pt icon, where `micro` is too wide.
        static let iconLabel = AppFonts.onest(size: 8, weight: .semibold)
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
/// sizes, units or percentages uses `Font.numbers` instead.
enum AppFonts {
    private static let isRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "OnestText", withExtension: "ttf") else { return false }
        var error: Unmanaged<CFError>?
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()

    private static var specs: [Font: (size: CGFloat, weight: Font.Weight)] = [:]
    private static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]

    static func onest(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Without the font file, fall back to the system font, not a missing face.
        let font = isRegistered
            ? Font.custom("Onest", size: size).weight(weight)
            : Font.system(size: size, weight: weight)
        specs[font] = (size, weight)
        // Call sites adjust a style with `.weight(_:)`; remember those too so
        // `.numbers` finds them.
        for variant in weights {
            specs[font.weight(variant)] = (size, variant)
        }
        return font
    }

    /// SF Rounded at an Onest style's size and weight, for numbers.
    static func roundedNumbers(matching font: Font?) -> Font? {
        guard let font, let spec = specs[font] else { return nil }
        return .system(size: spec.size, weight: spec.weight, design: .rounded)
    }
}

extension Font {
    /// SF Rounded at this Onest style's size and weight, for sizes, units and
    /// percentages. System styles, such as `display`, come back unchanged.
    var numbers: Font {
        AppFonts.roundedNumbers(matching: self) ?? self
    }
}
