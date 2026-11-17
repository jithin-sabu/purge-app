import SwiftUI

/// The compact face of a project card. A single folder is already a complete
/// cleanup target; only cards with multiple visible folders need disclosure.
struct DeveloperProjectHeader: View {
    let group: ProjectGroup
    let artifacts: [ProjectCacheArtifact]
    let level: SafetyLevel
    let isExpanded: Bool
    let selectionState: SelectAllTriState
    let onToggleSelection: () -> Void
    let onToggleExpanded: () -> Void
    let onSetSafety: ((SafetyLevel) -> Void)?
    let onResetToAutomatic: (() -> Void)?

    @State private var showsDetails = false

    private var singleArtifact: ProjectCacheArtifact? {
        artifacts.count == 1 ? artifacts.first : nil
    }

    private var summary: String {
        if let artifact = singleArtifact {
            guard artifact.lastModified > .distantPast else { return artifact.kind.rowTag }
            let date = artifact.lastModified.formatted(date: .abbreviated, time: .omitted)
            return String(localized: "\(artifact.kind.rowTag) · Modified \(date)")
        }
        var labels: [String] = []
        for artifact in artifacts where !labels.contains(artifact.kind.rowTag) {
            labels.append(artifact.kind.rowTag)
        }
        return String(localized: "\(artifacts.count) folders") + " · " + labels.joined(separator: String(localized: ", "))
    }

    private var warning: String? {
        if artifacts.contains(where: { $0.gitStatus == .dirty }) {
            return String(localized: "Local changes nearby")
        }
        if artifacts.contains(where: { $0.reinstallSafety == .missingLockfile }) {
            return String(localized: "Check support files")
        }
        return nil
    }

    private var iconGroup: ProjectGroup {
        var visible = group
        visible.artifacts = artifacts
        return visible
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            TriStateCheckbox(title: "", state: selectionState, action: onToggleSelection)
                .accessibilityLabel("Select all \(group.reviewTitle) items")
                .frame(width: 24)

            Button(action: singleArtifact == nil ? onToggleExpanded : onToggleSelection) {
                HStack(spacing: AppStyle.Spacing.small) {
                    AdaptiveBrandIconImage(source: .projectGroup(iconGroup))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                        Text(group.reviewTitle)
                            .font(AppStyle.Typography.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(summary)
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.rootPath.path)
            .accessibilityLabel(Text(verbatim: group.reviewTitle + ". " + summary))
            .accessibilityHint(singleArtifact == nil
                ? (isExpanded ? Text("Collapse project") : Text("Expand project"))
                : Text("Select cleanup item"))

            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xSmall) {
                Text(formatBytes(artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }))
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .monospacedDigit()
                if let onSetSafety {
                    Menu {
                        Button("Safe to Clean") { onSetSafety(.safe) }
                        Button("Check First") { onSetSafety(.medium) }
                        if let onResetToAutomatic {
                            Divider()
                            Button("Use automatic category", action: onResetToAutomatic)
                        }
                    } label: { Text(level.displayName) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    // Keep a real native menu label as the hit target. macOS
                    // flattens a custom menu label, so draw the shared badge over
                    // it without intercepting the menu's input.
                    .overlay {
                        AppBadge(level: level)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .help("Change cleanup category")
                    .accessibilityLabel(Text("Cleanup category"))
                    .accessibilityValue(level.displayName)
                } else {
                    AppBadge(level: level)
                }
            }

            Button { showsDetails.toggle() } label: {
                Image(systemName: warning == nil ? "info.circle" : "exclamationmark.circle")
                    .foregroundStyle(warning == nil ? AppColors.textSecondary : AppColors.statusCheckText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(warning ?? String(localized: "Project details"))
            .accessibilityLabel(Text("Project details"))
            .accessibilityHint(Text(verbatim: warning ?? ""))
            .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
                details
            }

            if singleArtifact == nil {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? Text("Collapse project") : Text("Expand project"))
            }
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(minHeight: AppStyle.Row.listRowMinHeight)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                Text(group.reviewTitle).font(AppStyle.Typography.sectionTitle)
                Text(group.rootPath.path)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .textSelection(.enabled)
                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                        HStack {
                            Text(artifact.safetyInfo.headline).font(AppStyle.Typography.rowTitle)
                            Spacer()
                            Text(artifact.formattedSize).font(AppStyle.Typography.metadata.numbers)
                        }
                        Text(artifact.path.path)
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                            .textSelection(.enabled)
                        if artifact.lastModified > .distantPast {
                            Text(String(localized: "Build data modified \(artifact.lastModified.formatted(date: .abbreviated, time: .omitted))"))
                                .font(AppStyle.Typography.metadata)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        Text(LocalizedStringKey(artifact.safetyInfo.explanation))
                            .font(AppStyle.Typography.callout)
                        if let reason = artifact.checkFirstReason, artifact.safetyInfo.level == .medium {
                            Text(reason.summary).font(AppStyle.Typography.callout)
                        }
                        if artifact.reinstallSafety == .reinstallable {
                            AppBadge(text: String(localized: "Can be rebuilt"), tone: .safe)
                        } else if artifact.reinstallSafety == .missingLockfile {
                            Text("Check support files").font(AppStyle.Typography.metadata)
                                .foregroundStyle(AppColors.statusCheckText)
                        }
                        if artifact.gitStatus == .dirty {
                            Text("Local changes nearby").font(AppStyle.Typography.metadata)
                                .foregroundStyle(AppColors.statusCheckText)
                        }
                        if !artifact.safetyInfo.recoverySteps.isEmpty {
                            Text(LocalizedStringKey(artifact.safetyInfo.recoverySteps))
                                .font(AppStyle.Typography.metadata)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        HStack(spacing: AppStyle.Spacing.small) {
                            Button("Show in Finder") { FinderReveal.show(artifact.path) }
                            Button("Copy Path") { FinderReveal.copyPaths([artifact.path]) }
                        }
                        .buttonStyle(.purge(.secondary, size: .small))
                    }
                }
            }
            .padding(AppStyle.Spacing.large)
        }
        .frame(width: 420)
        .frame(maxHeight: 500)
    }
}
