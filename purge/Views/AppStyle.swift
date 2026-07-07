import SwiftUI

enum AppStyle {
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let panel: CGFloat = 12
        static let card: CGFloat = 14
    }

    enum Spacing {
        static let xxSmall: CGFloat = 4
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
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
        static let projectGroupIconCornerRadius: CGFloat = 5
        /// Aligns expanded artifact text with the project title (parent checkbox + spacing).
        static let projectArtifactLeadingInset: CGFloat = 34
        /// Inner horizontal padding for scan result cards (matches `ScanResultRow` chrome).
        static let scanCardHorizontalPadding: CGFloat = 14
    }

    enum Typography {
        static let pageTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let rowTitle = Font.system(size: 13, weight: .medium)
        static let metadata = Font.system(size: 11)
        static let metadataEmphasis = Font.system(size: 11, weight: .medium)
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
