import SwiftUI

/// The header of the Xcode build folders card in Dev Tools (#480), laid out
/// like a project card's: checkbox, icon, title and summary, size and badge,
/// then the chevron that opens the card in place.
struct XcodeBuildFolderGroupHeader: View {
    let iconTool: DevTool
    let folderCount: Int
    let bytes: Int64
    let isExpanded: Bool
    let selectionState: SelectAllTriState
    let onToggleSelection: () -> Void
    let onToggleExpanded: () -> Void

    private var title: String { String(localized: "Xcode build folders") }

    private var summary: String {
        String(localized: "\(folderCount) folders") + " · " + String(localized: "Built outside Xcode's own folder")
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            TriStateCheckbox(title: "", state: selectionState, action: onToggleSelection)
                .accessibilityLabel(Text("Select all Xcode build folders"))
                .frame(width: 24)

            HStack(spacing: AppStyle.Spacing.small) {
                AdaptiveBrandIconImage(source: .devTool(iconTool))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    Text(title)
                        .font(AppStyle.Typography.headline)
                        .lineLimit(1)
                    Text(summary)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title + ". " + summary))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? Text("Hide folders") : Text("Show folders"))
            .accessibilityAction { onToggleExpanded() }

            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xSmall) {
                Text(formatBytes(bytes))
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .monospacedDigit()
                AppBadge(level: .medium)
            }

            XcodeBuildFolderChevron(isExpanded: isExpanded, action: onToggleExpanded)
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(minHeight: AppStyle.Row.listRowMinHeight)
    }
}

/// One part of the card: the folders whose project is gone, or the ones whose
/// project is still on this Mac. Its checkbox ticks that part alone.
struct XcodeBuildFolderPartHeader: View {
    let part: XcodeBuildFolderGroup.Part
    let folderCount: Int
    let bytes: Int64
    let isExpanded: Bool
    let selectionState: SelectAllTriState
    let onToggleSelection: () -> Void
    let onToggleExpanded: () -> Void

    private var title: String {
        switch part {
        case .projectGone: String(localized: "Project no longer on this Mac")
        case .projectHere: String(localized: "Project still on this Mac")
        }
    }

    private var summary: String { String(localized: "\(folderCount) folders") }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            TriStateCheckbox(title: "", state: selectionState, action: onToggleSelection)
                .accessibilityLabel(Text("Select \(title)"))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(title)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                Text(summary)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title + ". " + summary))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? Text("Hide folders") : Text("Show folders"))
            .accessibilityAction { onToggleExpanded() }

            Text(formatBytes(bytes))
                .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()

            XcodeBuildFolderChevron(isExpanded: isExpanded, action: onToggleExpanded)
        }
        .padding(.leading, AppStyle.Row.projectArtifactLeadingInset)
        .padding(.trailing, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .frame(minHeight: AppStyle.Row.parentHeight)
    }
}

/// The project card's chevron, as a button.
private struct XcodeBuildFolderChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? Text("Hide folders") : Text("Show folders"))
    }
}
