import SwiftUI

// MARK: - Section

/// The uninstaller's Command-line tools section (#225). Every row is the same
/// two-line card with a checkbox. Tools installed by a script move to the
/// Trash; tools a package manager installed are removed by that manager. One
/// Remove covers both, through `CommandLineToolReviewSheet`.
struct CommandLineToolsSection: View {
    @EnvironmentObject private var store: PurgeStore

    private var standalone: [StandaloneCommandLineTool] { store.commandLineTools.standalone }
    private var managed: [PackageManagerTool] { store.commandLineTools.managed }
    private var allIDs: [String] { standalone.map(\.id) + managed.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !standalone.isEmpty {
                        UninstallSectionHeader(title: String(localized: "Installed by a script"))
                        ForEach(standalone) { tool in
                            CommandLineToolRow(
                                name: tool.name,
                                detail: standaloneDetail(tool),
                                symbolName: "terminal",
                                sizeBytes: tool.sizeBytes,
                                runsInBackground: !tool.install.launchAgents.isEmpty,
                                locations: [ScanRowLocation(url: tool.folder, sizeBytes: tool.sizeBytes)],
                                isSelected: selection(tool.id)
                            )
                        }
                    }
                    if !managed.isEmpty {
                        UninstallSectionHeader(title: String(localized: "Installed by a package manager"))
                        .padding(.top, standalone.isEmpty ? 0 : AppStyle.Spacing.small)
                        ForEach(managed) { tool in
                            CommandLineToolRow(
                                name: tool.name,
                                detail: [tool.manager.displayName, tool.context].compactMap { $0 }.joined(separator: " · "),
                                symbolName: "shippingbox",
                                sizeBytes: tool.sizeBytes,
                                runsInBackground: false,
                                locations: tool.locations.map { ScanRowLocation(url: $0) },
                                isSelected: selection(tool.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, AppDetailPageLayout.horizontalInset)
                .padding(.top, 2)
                .padding(.bottom, AppStyle.Spacing.large)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.surfaceBase)
        }
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.commandLineToolSelectedIDs.contains(id) },
            set: { _ in store.toggleCommandLineToolSelected(id: id) }
        )
    }

    /// The folder, then how many commands start the tool.
    private func standaloneDetail(_ tool: StandaloneCommandLineTool) -> String {
        let path = displayDirectoryPath(for: tool.folder)
        let count = tool.install.shims.count
        let commands: String
        switch count {
        case 0: commands = String(localized: "No commands")
        case 1: commands = String(localized: "1 command")
        default: commands = String(localized: "\(count) commands")
        }
        return "\(path) · \(commands)"
    }

    private var selectAllState: SelectAllTriState {
        let ids = allIDs
        guard !ids.isEmpty else { return .none }
        let selected = ids.filter { store.commandLineToolSelectedIDs.contains($0) }.count
        if selected == 0 { return .none }
        if selected == ids.count { return .all }
        return .mixed
    }

    private var toolbar: some View {
        HStack(alignment: .bottom) {
            TriStateCheckbox(title: String(localized: "Select All"), state: selectAllState) {
                store.setAllCommandLineToolsSelected(selectAllState != .all, ids: allIDs)
            }
            .fixedSize()
            Spacer()
        }
        .scanTabSelectAllRowLayout()
    }
}

// MARK: - Row

/// One tool: checkbox, icon, name and one detail line, size. The same shape
/// for both kinds, so the list reads as one.
private struct CommandLineToolRow: View {
    let name: String
    let detail: String
    let symbolName: String
    let sizeBytes: Int64
    let runsInBackground: Bool
    let locations: [ScanRowLocation]
    @Binding var isSelected: Bool

    @State private var isContextMenuActive = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.actionPrimary)
                .allowsHitTesting(false)

            Image(systemName: symbolName)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppStyle.Spacing.xSmall) {
                    Text(name)
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if runsInBackground {
                        Text("Runs in background")
                            .font(AppStyle.Typography.micro)
                            .foregroundStyle(AppColors.statusCheckText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(AppColors.statusCheckFill))
                            .fixedSize()
                    }
                }
                Text(detail)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            Text(formatBytes(sizeBytes))
                .font(AppStyle.Typography.metadataEmphasis.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(isContextMenuActive ? AppColors.surfaceCardHover : AppColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
        .finderRevealMenu(isMenuActive: $isContextMenuActive) { locations }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.12), value: isContextMenuActive)
    }
}

// MARK: - Removal sheet

/// The one confirm for every ticked tool. Script installs list every path
/// that moves to the Trash, the settings that go with each folder, what stays,
/// and the background jobs Purge stops first. Package-manager tools list the
/// exact command each manager runs, and that it deletes permanently. Once the
/// removal runs, each card shows how it went; a refusal before it starts stays
/// in the sheet.
struct CommandLineToolReviewSheet: View {
    let plan: CommandLineToolRemovalPlan
    let onClose: () -> Void
    let onConfirm: () -> Void

    static let settingsShown = 8

    /// Script installs wait in the Trash. Only what a package manager removes is
    /// freed straight away (#191).
    static func sizeLine(for plan: CommandLineToolRemovalPlan) -> String {
        RemovalSizeLine.text(
            toTrash: RemovalSizeLine.total(plan.tools, \.sizeBytes),
            permanently: RemovalSizeLine.total(plan.managed, \.sizeBytes)
        )
    }

    private var isBusy: Bool {
        switch plan.phase {
        case .checking, .working: return true
        case .review, .finished: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    if !plan.tools.isEmpty {
                        groupTitle(String(localized: "Moves to the Trash"))
                        ForEach(plan.tools) { tool in
                            toolCard(tool)
                        }
                    }
                    if !plan.managed.isEmpty {
                        groupTitle(String(localized: "Removed by its package manager, permanently"))
                            .padding(.top, plan.tools.isEmpty ? 0 : AppStyle.Spacing.xSmall)
                        ForEach(plan.managed) { tool in
                            managedCard(tool)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240)

            if let refusal = plan.refusal {
                note(refusal)
            }

            footer
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 600, minHeight: 520)
        .background(AppColors.surfaceBase)
        .interactiveDismissDisabled(isBusy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text(titleText)
                .font(AppStyle.Typography.pageTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text(introText)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: String {
        if plan.phase == .finished {
            return plan.failedCount == 0
                ? String(localized: "Command-line tools removed")
                : String(localized: "Some tools weren't removed")
        }
        if plan.itemCount == 1 {
            let name = plan.tools.first?.name ?? plan.managed.first?.name ?? ""
            return String(localized: "Remove \(name)?")
        }
        return String(localized: "Remove \(plan.itemCount) command-line tools?")
    }

    private var introText: String {
        var parts: [String] = []
        if !plan.tools.isEmpty {
            parts.append(String(localized: "Each tool's folder and the commands that start it move to the Trash, so you can put them back until you empty it. Settings, keys and history inside the folder go with it. Purge first checks that nothing is using these files."))
        }
        if !plan.managed.isEmpty {
            parts.append(String(localized: "Tools a package manager installed are removed by that manager, with its own checks. It deletes them permanently. They aren't moved to the Trash."))
        }
        return parts.joined(separator: " ")
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(AppStyle.Typography.headline)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, AppStyle.Spacing.xxSmall)
            .accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) { content() }
            .padding(AppStyle.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .fill(AppColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            )
    }

    private func cardTitle(_ name: String, bytes: Int64, state: CommandLineToolRemovalPlan.ItemState) -> some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Text(name)
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            statusView(state)
            Text(formatBytes(bytes))
                .font(AppStyle.Typography.metadataEmphasis.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func statusView(_ state: CommandLineToolRemovalPlan.ItemState) -> some View {
        switch state {
        case .waiting:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .movedToTrash:
            statusLabel(String(localized: "Moved to Trash"), symbol: "checkmark.circle.fill", color: AppColors.statusSafeText)
        case .removedByManager:
            statusLabel(String(localized: "Removed"), symbol: "checkmark.circle.fill", color: AppColors.statusSafeText)
        case .failed:
            statusLabel(String(localized: "Not removed"), symbol: "exclamationmark.triangle.fill", color: AppColors.statusDangerText)
        case .managerMissing:
            statusLabel(String(localized: "Not run"), symbol: "exclamationmark.circle.fill", color: AppColors.statusCheckText)
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: AppStyle.Spacing.xxSmall) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text)
        }
        .font(AppStyle.Typography.metadataEmphasis)
        .foregroundStyle(color)
    }

    private func detailLine(_ text: String, color: Color = AppColors.textSecondary) -> some View {
        Text(text)
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolCard(_ tool: StandaloneCommandLineTool) -> some View {
        card {
            cardTitle(tool.name, bytes: tool.sizeBytes, state: plan.state(of: tool.id))
            ForEach(tool.install.removalPaths, id: \.self) { url in
                Text(displayDirectoryPath(for: url))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !tool.settingsFiles.isEmpty {
                detailLine(settingsLine(tool.settingsFiles), color: AppColors.statusCheckText)
            }
            ForEach(tool.install.launchAgents, id: \.label) { job in
                detailLine(String(localized: "Purge stops the background job \(job.label) first."), color: AppColors.statusCheckText)
            }
            if !tool.install.kept.isEmpty {
                let kept = ListFormatter.localizedString(byJoining: tool.install.kept.map { displayDirectoryPath(for: $0) })
                detailLine(String(localized: "Stays: \(kept)"))
            }
            if case .failed(let message) = plan.state(of: tool.id) {
                detailLine(message, color: AppColors.statusDangerText)
            }
        }
    }

    private func managedCard(_ tool: PackageManagerTool) -> some View {
        card {
            cardTitle(tool.name, bytes: tool.sizeBytes, state: plan.state(of: tool.id))
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Text(tool.command)
                    .font(AppStyle.Typography.metadata.monospaced())
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let context = tool.context {
                    Text(context)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                }
                Spacer(minLength: 0)
                if !tool.canRun {
                    Button(String(localized: "Copy Command")) { FinderReveal.copyText(tool.command) }
                        .buttonStyle(.purge(.quiet, size: .small))
                }
            }
            if !tool.canRun {
                detailLine(
                    String(localized: "Purge couldn't find \(tool.manager.displayName) on this Mac. Copy the command and run it in Terminal."),
                    color: AppColors.statusCheckText
                )
            }
            if case .failed(let message) = plan.state(of: tool.id) {
                Text(message)
                    .font(AppStyle.Typography.metadata.monospaced())
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppStyle.Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                            .fill(AppColors.statusDangerFill)
                    )
            }
        }
    }

    private func settingsLine(_ files: [String]) -> String {
        let shown = Array(files.prefix(Self.settingsShown))
        let list = ListFormatter.localizedString(byJoining: shown)
        let more = files.count - shown.count
        return more > 0
            ? String(localized: "Your settings go too: \(list) and \(more) more")
            : String(localized: "Your settings go too: \(list)")
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.statusDangerText)
                .accessibilityHidden(true)
            Text(text)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .fill(AppColors.statusDangerFill)
        )
    }

    private var footer: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            switch plan.phase {
            case .review, .checking:
                Text(Self.sizeLine(for: plan))
                    .font(AppStyle.Typography.metadataEmphasis.numbers)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(action: onConfirm) {
                    CleaningButtonLabel(
                        title: plan.phase == .checking
                            ? String(localized: "Checking...")
                            : (plan.refusal == nil
                                ? String(localized: "Remove \(plan.itemCount)")
                                : String(localized: "Try Again")),
                        systemImage: nil,
                        isCleaning: plan.phase == .checking
                    )
                }
                .buttonStyle(.purge(.destructive))
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            case .working:
                Text("Removing…")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.purge(.primary))
                    .disabled(true)
            case .finished:
                Text(plan.failedCount == 0
                     ? String(localized: "All removed")
                     : String(localized: "\(plan.failedCount) not removed"))
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
