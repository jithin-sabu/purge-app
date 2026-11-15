import SwiftUI

// Views for a vendor's apps shown as one group in the App Uninstaller (#155).
// The members stay ordinary app tiles and rows; these are the group's own
// tile, list header, and notes.

/// A group's icon (#155): its lead app in front with up to two more fanned
/// behind, like a hand of cards. Hovering spreads the fan a little.
struct AppGroupFan: View {
    let apps: [InstalledApp]
    let groupName: String
    /// The front icon's side; the fan is about twice as wide.
    let iconSide: CGFloat
    var isSpread = false
    /// A tighter fan for the list's 36pt icon column.
    var isCompact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The lead app first: the one named like the folder, else the largest.
    /// The vendor's uninstaller goes last, so it is never the face of a group.
    static func ordered(_ apps: [InstalledApp], groupName: String) -> [InstalledApp] {
        let isUninstaller: (InstalledApp) -> Bool = { AppSuiteGrouping.uninstaller(in: [$0]) != nil }
        let rest = apps.filter { !isUninstaller($0) }.sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
        let lead = rest.first { $0.name.localizedCaseInsensitiveCompare(groupName) == .orderedSame }
            ?? rest.first { $0.name.localizedCaseInsensitiveContains(groupName) }
            ?? rest.first
        let others = rest.filter { $0.id != lead?.id } + apps.filter(isUninstaller)
        return (lead.map { [$0] } ?? []) + others
    }

    var body: some View {
        let shown = Array(Self.ordered(apps, groupName: groupName).prefix(3))
        // Back-to-front slot for each shown icon: the lead sits in the middle.
        let slots: [Int] = shown.count == 2 ? [1, 0] : [1, 0, 2]
        let center = CGFloat(shown.count - 1) / 2
        let angle: Double = (shown.count == 2 ? 12 : 16) * (isSpread ? 1.3 : 1) * (isCompact ? 0.75 : 1)
        let step = iconSide * (isSpread ? 0.4 : 0.28) * (isCompact ? 0.75 : 1)
        ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, app in
                let slot = CGFloat(slots[index])
                Image(nsImage: BrandIconService.shared.installedAppIcon(at: app.bundleURL))
                    .resizable()
                    .frame(width: iconSide, height: iconSide)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                    .rotationEffect(.degrees(angle * Double(slot - center) / max(center, 1)), anchor: .bottom)
                    .offset(x: (slot - center) * step)
                    .zIndex(index == 0 ? 1 : 0)
            }
        }
        .frame(width: iconSide * 2, height: iconSide)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72), value: isSpread)
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
            AppGroupFan(apps: apps, groupName: group.name, iconSide: 46, isSpread: isHovering)
                .frame(height: 56)
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

            AppGroupFan(apps: apps, groupName: group.name, iconSide: 26, isSpread: isHovering, isCompact: true)
                .frame(width: 36, height: 36)

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
        switch suite.kind {
        case .uninstallerRemoved:
            return String(localized: "\(suite.uninstallerName) is the uninstaller that came with \(suite.groupName). Open it first, so it can remove the parts it installed outside this folder.")
        case .someParts:
            return String(localized: "You picked \(suite.pickedCount) of \(suite.totalCount) apps in \(suite.groupName). Removing only some of them can stop its own uninstaller from removing the rest.")
        }
    }
}
