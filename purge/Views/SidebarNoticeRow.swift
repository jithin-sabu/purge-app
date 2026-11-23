import SwiftUI

/// A one-line notice at the foot of the sidebar: an icon, a title, a short hint and
/// a chevron, on the same card as the Trash total. Clicking it opens the place that
/// explains the problem and fixes it, so the sidebar never carries a big button that
/// competes with the page's own main action. Limited scan and the paused deleted-app
/// reviews both use it, so stacked notices read as one family.
struct SidebarNoticeRow: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                    Text(title)
                        .font(AppStyle.Typography.callout.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(AppStyle.Typography.metadataEmphasis)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.vertical, AppStyle.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .fill(AppColors.fillSecondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous))
        }
        .buttonStyle(SidebarNoticeButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .transition(.opacity)
    }
}

private struct SidebarNoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
