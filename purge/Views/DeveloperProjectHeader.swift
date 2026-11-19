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

            // A tap area rather than a Button, so the info button can sit beside the
            // title without nesting one button in another.
            HStack(spacing: AppStyle.Spacing.small) {
                AdaptiveBrandIconImage(source: .projectGroup(iconGroup))
                    .accessibilityHidden(true)
                titleColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: primaryAction)
            .help(group.rootPath.path)

            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xSmall) {
                Text(formatBytes(artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }))
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .monospacedDigit()
                AppBadge(level: level)
            }

            // The slot stays on single-folder cards too, so sizes and badges line
            // up down the list.
            if singleArtifact == nil {
                Button(action: onToggleExpanded) {
                    chevron
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? Text("Collapse project") : Text("Expand project"))
            } else {
                chevron
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(minHeight: AppStyle.Row.listRowMinHeight)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                titleText
                // Outside the title's Text, so a long title truncates before
                // the button does.
                infoButton
                    .fixedSize()
            }
            Text(summary)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHidden(true)
        }
    }

    private var titleText: some View {
        let label = Text(verbatim: group.reviewTitle + ". " + summary)
        return Text(group.reviewTitle)
            .font(AppStyle.Typography.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(label)
            .accessibilityHint(primaryActionHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { primaryAction() }
    }

    private func primaryAction() {
        if singleArtifact == nil { onToggleExpanded() } else { onToggleSelection() }
    }

    private var primaryActionHint: Text {
        singleArtifact == nil
            ? (isExpanded ? Text("Collapse project") : Text("Expand project"))
            : Text("Select cleanup item")
    }

    /// Beside the title, like Purgeable's on Overview. A warning turns it into
    /// an exclamation mark in the Check First colour.
    private var infoButton: some View {
        Button { showsDetails.toggle() } label: {
            Image(systemName: warning == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(warning == nil ? AppColors.textTertiary : AppColors.statusCheckText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(warning ?? String(localized: "Project details"))
        .accessibilityLabel(Text("Project details"))
        .accessibilityHint(Text(verbatim: warning ?? ""))
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            details
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColors.textSecondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                // Title and path read as one unit.
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    Text(group.reviewTitle).font(AppStyle.Typography.sectionTitle)
                    Text(group.rootPath.path)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .textSelection(.enabled)
                }
                if let reason = artifacts.lazy.filter({ $0.safetyInfo.level == .medium })
                    .compactMap(\.checkFirstReason).first {
                    Text(reason.summary)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.statusCheckText)
                }
                ForEach(artifacts) { artifact in
                    // Each folder is its own thing; a rule keeps them apart.
                    Divider()
                    folderDetail(artifact)
                }
            }
            .padding(AppStyle.Spacing.large)
        }
        .frame(width: 420)
        .frame(maxHeight: 500)
    }

    /// One folder: its name with the rebuild badge beside it, the path with the
    /// Finder and copy icons that act on it, then the explanation. No date: the
    /// folder's own modified date says little about use, and the Check First
    /// reason above already covers when the project was worked on.
    private func folderDetail(_ artifact: ProjectCacheArtifact) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            HStack(spacing: AppStyle.Spacing.small) {
                Text(artifact.safetyInfo.headline).font(AppStyle.Typography.rowTitle)
                if artifact.reinstallSafety == .reinstallable {
                    AppBadge(text: String(localized: "Can be rebuilt"), tone: .safe)
                }
                Spacer()
                Text(artifact.formattedSize).font(AppStyle.Typography.metadata.numbers)
            }
            folderPathLine(artifact)
            Text(LocalizedStringKey(artifact.safetyInfo.explanation))
                .font(AppStyle.Typography.callout)
            if artifact.reinstallSafety == .missingLockfile {
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
        }
    }

    /// The path, then the icons that act on it, kept at the right edge so they
    /// line up from folder to folder. A path that fits reads left to right like
    /// the project path above. One too long for the line keeps its end, the
    /// folder the row is about, and fades out at its start. Hover shows all of
    /// it, and Copy Path copies all of it.
    private func folderPathLine(_ artifact: ProjectCacheArtifact) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                pathText(artifact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pathText(artifact)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    .clipped()
                    .mask(Self.pathStartFade)
            }
            .help(artifact.path.path)
            detailIconButton("folder", help: String(localized: "Show in Finder")) {
                FinderReveal.show(artifact.path)
            }
            detailIconButton("doc.on.doc", help: String(localized: "Copy Path")) {
                FinderReveal.copyPaths([artifact.path])
            }
        }
    }

    private func pathText(_ artifact: ProjectCacheArtifact) -> some View {
        Text(artifact.path.path)
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(AppColors.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
    }

    /// Clear at the start of the line, then opaque. A mask's colours only set
    /// opacity, so they aren't design colours.
    private static let pathStartFade = LinearGradient(
        stops: [
            .init(color: .clear, location: 0), // design-lint: allow
            .init(color: .black, location: 0.18), // design-lint: allow
            .init(color: .black, location: 1), // design-lint: allow
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private func detailIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}
