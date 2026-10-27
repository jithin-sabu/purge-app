import SwiftUI

/// One found item on the onboarding first-scan step.
struct ScanListRow: View {
    let icon: AdaptiveBrandIconImage.Source
    let title: String
    let formattedSize: String

    var body: some View {
        HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
            AdaptiveBrandIconImage(source: icon)

            Text(title)
                .font(AppStyle.Typography.rowTitle)
                .lineLimit(1)

            Spacer(minLength: AppStyle.Spacing.xSmall)

            Text(formattedSize)
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                // The box a hidden size-and-badge placeholder used to give it, so
                // the size still sits where it did.
                .frame(minWidth: 92, minHeight: 36, alignment: .topTrailing)
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, 10)
        .frame(minHeight: AppStyle.Row.listRowMinHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(AppColors.fillSecondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .stroke(AppColors.borderSubtle)
        }
    }
}

enum ScanListRowInsets {
    /// The plain macOS List adds an outer inset. This remainder aligns scan
    /// cards with the page controls on App Caches, Dev Tools and Large Files.
    static let standard = EdgeInsets(
        top: AppStyle.Spacing.xxSmall,
        leading: AppStyle.Spacing.medium,
        bottom: AppStyle.Spacing.xxSmall,
        trailing: AppStyle.Spacing.medium
    )
}

struct ScanListBottomSpacer: View {
    var body: some View {
        Color.clear
            .frame(height: AppStyle.Spacing.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
    }
}
