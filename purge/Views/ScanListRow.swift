import AppKit
import SwiftUI

enum ScanListRowIcon {
    case symbol(String)
    case image(NSImage)
}

struct ScanListRow<Footer: View>: View {
    let icon: ScanListRowIcon
    let title: String
    let subtitle: String?
    let formattedSize: String
    let primaryBadgeText: String?
    let primaryBadgeTone: AppBadge.Tone
    let isSelected: Bool
    let isHovering: Bool
    let isTrailingMetadataPending: Bool
    @ViewBuilder let footer: () -> Footer

    init(
        icon: ScanListRowIcon,
        title: String,
        subtitle: String? = nil,
        formattedSize: String,
        primaryBadgeText: String?,
        primaryBadgeTone: AppBadge.Tone = .neutral,
        isSelected: Bool = false,
        isHovering: Bool = false,
        isTrailingMetadataPending: Bool = false,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.formattedSize = formattedSize
        self.primaryBadgeText = primaryBadgeText
        self.primaryBadgeTone = primaryBadgeTone
        self.isSelected = isSelected
        self.isHovering = isHovering
        self.isTrailingMetadataPending = isTrailingMetadataPending
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
                iconView

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: AppStyle.Spacing.xSmall)

                ScanContentCrossfade(isLoading: isTrailingMetadataPending) {
                    SkeletonBar(width: 44, height: 10, cornerRadius: 4)
                        .shimmering()
                    SkeletonBar(width: 72, height: 18, cornerRadius: AppStyle.Radius.chip)
                        .shimmering()
                } loaded: {
                    Text(formattedSize)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if let primaryBadgeText {
                        AppBadge(text: primaryBadgeText, tone: primaryBadgeTone)
                    }
                }
            }

            footer()
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, 10)
        .frame(minHeight: AppStyle.Row.listRowMinHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .fill(AppStyle.elevated)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                            .fill(AppStyle.selectionFill)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                            .fill(AppStyle.rowHover)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .stroke(isSelected ? AppStyle.selectionStroke : AppStyle.hairline)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(0.88)
        }
    }
}

extension ScanListRow where Footer == EmptyView {
    init(
        icon: ScanListRowIcon,
        title: String,
        subtitle: String? = nil,
        formattedSize: String,
        primaryBadgeText: String?,
        primaryBadgeTone: AppBadge.Tone = .neutral,
        isSelected: Bool = false,
        isHovering: Bool = false,
        isTrailingMetadataPending: Bool = false
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            formattedSize: formattedSize,
            primaryBadgeText: primaryBadgeText,
            primaryBadgeTone: primaryBadgeTone,
            isSelected: isSelected,
            isHovering: isHovering,
            isTrailingMetadataPending: isTrailingMetadataPending,
            footer: { EmptyView() }
        )
    }
}

enum ScanListRowInsets {
    static let standard = EdgeInsets(
        top: 4,
        leading: AppStyle.Spacing.small,
        bottom: 4,
        trailing: AppStyle.Spacing.small
    )
}
