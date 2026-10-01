import SwiftUI

enum AppStyle {
    /// Corner radii. Action buttons and chips are capsules, so they take no
    /// radius token.
    enum Radius {
        /// Badges, progress bars, skeleton bars, small icon tiles.
        static let xs: CGFloat = 4
        /// Chips inside a field, dropdown rows, thumbnails, Overview tiles.
        static let sm: CGFloat = 6
        /// Controls that hold a value: pickers, fields, segmented controls.
        static let md: CGFloat = 8
        /// Cards, list rows, sheets, notices.
        static let lg: CGFloat = 14
        /// Panels floating on the cleanup celebration.
        static let xl: CGFloat = 18
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
        static let title = Font.system(size: 26, weight: .semibold, design: .rounded)
        static let pageTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
        /// Sheet titles, card headers, large buttons.
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        /// Group headers, emphasis, regular buttons.
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        /// List row titles, menu rows.
        static let rowTitle = Font.system(size: 13, weight: .medium)
        /// Helper text under controls, small buttons.
        static let callout = Font.system(size: 12)
        /// Sizes, dates, paths.
        static let metadata = Font.system(size: 11)
        static let metadataEmphasis = Font.system(size: 11, weight: .medium)
        /// Badges and count pills.
        static let micro = Font.system(size: 10, weight: .semibold)
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
