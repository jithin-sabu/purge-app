import SwiftUI

enum FilterChipStyle {
    case dropdown
    case tab
}

enum FilterChipTier {
    case neutral
    case safe
    case checkFirst
    case danger
    case unsure

    var selectedBackground: Color {
        switch self {
        case .neutral: return AppColors.surfaceRaised
        case .safe: return AppColors.statusSafeFill
        case .checkFirst: return AppColors.statusCheckFill
        case .danger: return AppColors.statusDangerFill
        case .unsure: return AppColors.statusUnsureFill
        }
    }

    var selectedForeground: Color {
        switch self {
        case .neutral: return AppColors.textPrimary
        case .safe: return AppColors.statusSafeText
        case .checkFirst: return AppColors.statusCheckText
        case .danger: return AppColors.statusDangerText
        case .unsure: return AppColors.statusUnsureText
        }
    }
}

struct FilterChip: View {
    var style: FilterChipStyle
    let label: String
    var isSelected: Bool = false
    var tier: FilterChipTier = .neutral
    var leadingSystemImage: String? = nil
    var count: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 5
    private static let contentSpacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
                    // Badged symbols (e.g. clock.badge.xmark) report a taller
                    // ideal size than a plain glyph. Size and clip so every
                    // chip shares one height.
                    .font(AppStyle.Typography.callout.weight(.medium))
                    .foregroundStyle(foregroundColor)
                    .frame(width: 14, height: 14)
                    .clipped()
                    .accessibilityHidden(true)
            }

            if !label.isEmpty {
                labelView
            }

            if style == .dropdown {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityHidden(true)
            } else if let count {
                Text("\(count)")
                    .font(AppStyle.Typography.rowTitle)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(countColor)
            }
        }
        .font(AppStyle.Typography.body)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background {
            Capsule(style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        }
        .contentShape(Capsule(style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var labelView: some View {
        if style == .tab {
            ZStack(alignment: .leading) {
                Text(label)
                    .font(AppStyle.Typography.headline)
                    .opacity(0)
                    .accessibilityHidden(true)
                Text(label)
                    .font(AppStyle.Typography.body.weight(isSelected ? .semibold : .regular))
            }
            .animation(nil, value: isSelected)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(label)
                .lineLimit(1)
        }
    }

    private var backgroundColor: Color {
        if style == .tab, isSelected {
            return tier.selectedBackground
        }
        return AppColors.fillSecondary
    }

    private var foregroundColor: Color {
        if style == .tab, isSelected {
            return tier.selectedForeground
        }
        return AppColors.textSecondary
    }

    private var countColor: Color {
        if style == .tab, isSelected {
            return tier.selectedForeground
        }
        return AppColors.textTertiary
    }
}

extension SafetyFilter {
    var chipTier: FilterChipTier {
        switch self {
        case .all: return .neutral
        case .safe: return .safe
        case .checkFirst: return .checkFirst
        }
    }
}
