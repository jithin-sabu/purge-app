import SwiftUI

// Views for a vendor's apps shown as one group in the App Uninstaller (#155).
// The members stay ordinary app tiles and rows; these are the group's own
// tile, list header, and notes.

/// Up to four member icons in a 2x2 square, so a group never reads as one app.
struct AppGroupMosaic: View {
    let apps: [InstalledApp]
    /// The square's side.
    let side: CGFloat

    /// Tighter in the list's small square, so its icons stay legible.
    private var gap: CGFloat { side < 48 ? AppStyle.Spacing.xxxSmall : AppStyle.Spacing.xxSmall }
    private var iconSide: CGFloat { (side - gap * 3) / 2 }

    var body: some View {
        let shown = Array(apps.prefix(4))
        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < shown.count {
                            Image(nsImage: BrandIconService.shared.installedAppIcon(at: shown[index].bundleURL))
                                .resizable()
                                .frame(width: iconSide, height: iconSide)
                        } else {
                            Color.clear.frame(width: iconSide, height: iconSide)
                        }
                    }
                }
            }
        }
        .padding(gap)
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .fill(AppColors.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

/// How many of a group's apps are ticked, for its checkbox.
enum AppGroupSelection {
    static func state(appIDs: [String], selected: Set<String>) -> SelectAllTriState {
        let picked = appIDs.filter(selected.contains).count
        if picked == 0 { return .none }
        return picked == appIDs.count ? .all : .mixed
    }

    /// "4 apps", or "4 apps · 1 selected" while some are ticked.
    static func countLine(total: Int, picked: Int) -> String {
        if picked == 0 { return String(localized: "\(total) apps") }
        return String(localized: "\(total) apps · \(picked) selected")
    }
}

/// A group in the grid: the same size as an app tile. A click opens the tray
/// under its row; the circle in the corner ticks or clears every app in it.
struct AppGroupTile: View {
    let group: AppSuiteGroup
    let apps: [InstalledApp]
    let size: AppRowSize
    let activityLabel: String?
    let selection: SelectAllTriState
    let pickedCount: Int
    let isOpen: Bool
    /// False when every member is from the last scan (#283), so none can be ticked.
    let canSelect: Bool
    let onToggleOpen: () -> Void
    let onToggleSelection: () -> Void

    @State private var isHovering = false
    @State private var isHoveringIndicator = false

    private var sizeText: String {
        let count = String(localized: "\(apps.count) apps")
        return size.isPending ? count : "\(count) · \(formatBytes(size.bytes))"
    }

    var body: some View {
        VStack(spacing: AppStyle.Spacing.xSmall) {
            AppGroupMosaic(apps: apps, side: 56)
                .frame(maxWidth: .infinity)

            VStack(spacing: AppStyle.Spacing.xxxSmall) {
                HStack(spacing: AppStyle.Spacing.xxSmall) {
                    Text(group.name)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(AppStyle.Typography.micro)
                        .foregroundStyle(AppColors.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }

                Text(sizeText)
                    .font(AppStyle.Typography.metadata.numbers)
                    .foregroundStyle(size.isFromLastScan ? AppColors.textTertiary : AppColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())

                if let activityLabel {
                    Text(activityLabel)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 96)
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.medium)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(AppColors.fillSecondary)
                .overlay {
                    if isOpen || isHovering {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                            .fill(AppColors.surfaceRaised)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .stroke(
                    selection == .all ? AppColors.actionPrimary : (isOpen ? AppColors.borderStrong : AppColors.borderSubtle),
                    lineWidth: selection == .all ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleOpen)
        .onHover { isHovering = $0 }
        .overlay(alignment: .topLeading) {
            if canSelect {
                selectionIndicator
                    .padding(AppStyle.Spacing.small)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggleSelection)
                    .onHover { isHoveringIndicator = $0 }
                    .help(selection == .all ? String(localized: "Clear every app in \(group.name)") : String(localized: "Select every app in \(group.name)"))
                    .accessibilityHidden(true)
            }
        }
        .help(group.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(group.name), \(apps.count) apps"))
        .accessibilityValue(AppGroupSelection.countLine(total: apps.count, picked: pickedCount))
        .accessibilityHint(isOpen ? String(localized: "Collapse group") : String(localized: "Expand group"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onToggleOpen)
        .accessibilityAction(named: Text(selection == .all ? "Clear every app in the group" : "Select every app in the group")) {
            if canSelect { onToggleSelection() }
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        switch selection {
        case .all:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppColors.actionPrimary)
                .background(Circle().fill(AppColors.fillSecondary).padding(1)) // design-lint: allow, sits the fill under the glyph's own circle
        case .mixed:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppColors.actionPrimary)
                .background(Circle().fill(AppColors.fillSecondary).padding(1)) // design-lint: allow, sits the fill under the glyph's own circle
        case .none:
            Image(systemName: "circle")
                .font(.system(size: 20))
                .foregroundStyle(isHoveringIndicator || isHovering ? AppColors.textSecondary : AppColors.textTertiary)
                .background(Circle().fill(AppColors.fillSecondary).padding(1)) // design-lint: allow, sits the fill under the glyph's own circle
        }
    }
}

/// A group in the list: checkbox, mosaic, name and count, size, chevron. A click
/// on the row opens or closes it; the checkbox ticks or clears every app.
struct AppGroupListRow: View {
    let group: AppSuiteGroup
    let apps: [InstalledApp]
    let size: AppRowSize
    let activityLabel: String?
    let selection: SelectAllTriState
    let pickedCount: Int
    let isExpanded: Bool
    let canSelect: Bool
    let onToggleExpanded: () -> Void
    let onToggleSelection: () -> Void

    @State private var isHovering = false

    private var detailLine: String {
        let folder = (group.folderURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return "\(folder) · \(AppGroupSelection.countLine(total: apps.count, picked: pickedCount))"
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            if canSelect {
                TriStateCheckbox(title: "", state: selection, action: onToggleSelection)
                    .fixedSize()
                    .accessibilityLabel(String(localized: "Select every app in \(group.name)"))
            } else {
                LastScanRowMarker()
            }

            AppGroupMosaic(apps: apps, side: 36)

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                HStack(spacing: AppStyle.Spacing.xxSmallPlus) {
                    Text(group.name)
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(AppStyle.Typography.micro)
                        .foregroundStyle(AppColors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                Text(detailLine)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppStyle.Spacing.small)

            if let activityLabel {
                Text(activityLabel)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            Text(size.isPending ? "…" : formatBytes(size.bytes))
                .font(AppStyle.Typography.metadataEmphasis.numbers)
                .foregroundStyle(size.isFromLastScan ? AppColors.textTertiary : AppColors.textSecondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(isHovering ? AppColors.surfaceCardHover : AppColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .strokeBorder(isExpanded ? AppColors.borderStrong : AppColors.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpanded)
        .onHover { isHovering = $0 }
        .help(group.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(group.name), \(apps.count) apps"))
        .accessibilityHint(isExpanded ? String(localized: "Collapse group") : String(localized: "Expand group"))
        .accessibilityAction(named: Text(isExpanded ? "Collapse group" : "Expand group"), onToggleExpanded)
        .finderRevealMenu(isMenuActive: .constant(false)) {
            [ScanRowLocation(url: group.folderURL)]
        }
    }
}

/// "DaVinci Resolve comes with its own uninstaller." with a button that opens it.
struct SuiteUninstallerNote: View {
    let groupName: String
    let uninstallerName: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "info.circle")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "\(groupName) comes with its own uninstaller."))
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppStyle.Spacing.small)
            Button(String(localized: "Open \(uninstallerName)"), action: onOpen)
                .buttonStyle(.purge(.secondary, size: .small))
                .fixedSize()
        }
    }
}

/// The review sheet's warning when a removal takes only some apps of a suite
/// that has its own uninstaller (#155).
struct PartialSuiteWarning: View {
    let suite: PartialSuite
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.statusCheckText)
                .accessibilityHidden(true)
            Text(Self.text(for: suite))
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "Open \(suite.uninstallerName)"), action: onOpen)
                .buttonStyle(.purge(.secondary, size: .small))
                .fixedSize()
        }
        .padding(AppStyle.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .fill(AppColors.statusCheckFill)
        )
        .accessibilityElement(children: .combine)
    }

    static func text(for suite: PartialSuite) -> String {
        String(localized: "You picked \(suite.pickedCount) of \(suite.totalCount) apps in \(suite.groupName). Removing only some of them can stop its own uninstaller from removing the rest.")
    }
}
