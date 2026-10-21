import SwiftUI

// MARK: - Section

/// The uninstaller's Command-line tools section (#225). Tools installed by a
/// script are removed by Purge, to the Trash, after a check that nothing is
/// using them. Tools a package manager installed are handed back to it.
struct CommandLineToolsSection: View {
    @EnvironmentObject private var store: PurgeStore

    private var standalone: [StandaloneCommandLineTool] { store.commandLineTools.standalone }
    private var managed: [PackageManagerTool] { store.commandLineTools.managed }

    var body: some View {
        VStack(spacing: 0) {
            if !standalone.isEmpty {
                toolbar
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !standalone.isEmpty {
                        sectionHeader(
                            String(localized: "Installed by a script"),
                            detail: String(localized: "Purge moves the tool's folder and its commands to the Trash. Settings inside the folder go with it.")
                        )
                        ForEach(standalone) { tool in
                            StandaloneToolRow(
                                tool: tool,
                                isSelected: Binding(
                                    get: { store.commandLineToolSelectedIDs.contains(tool.id) },
                                    set: { _ in store.toggleCommandLineToolSelected(id: tool.id) }
                                )
                            )
                        }
                    }
                    if !managed.isEmpty {
                        sectionHeader(
                            String(localized: "Installed by a package manager"),
                            detail: String(localized: "The package manager that installed each one removes it, with its own checks and records. It deletes them permanently, not to the Trash.")
                        )
                        .padding(.top, standalone.isEmpty ? 0 : AppStyle.Spacing.small)
                        ForEach(managed) { tool in
                            ManagedToolRow(tool: tool) {
                                store.requestPackageManagerUninstall(tool)
                            }
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

    private var selectAllState: SelectAllTriState {
        guard !standalone.isEmpty else { return .none }
        let selected = standalone.filter { store.commandLineToolSelectedIDs.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == standalone.count { return .all }
        return .mixed
    }

    private var toolbar: some View {
        HStack(alignment: .bottom) {
            TriStateCheckbox(title: String(localized: "Select All"), state: selectAllState) {
                store.setAllCommandLineToolsSelected(selectAllState != .all, ids: standalone.map(\.id))
            }
            .fixedSize()
            Spacer()
        }
        .scanTabSelectAllRowLayout()
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppStyle.Typography.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text(detail)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppStyle.Spacing.xxSmall)
        .padding(.bottom, AppStyle.Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Rows

/// Shared card chrome for both kinds of row.
private struct ToolRowCard: ViewModifier {
    let isMenuActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.vertical, AppStyle.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .fill(isMenuActive ? AppColors.surfaceCardHover : AppColors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            )
    }
}

/// The commands a standalone install puts on `PATH`, as one line.
private func commandsLine(_ shims: [URL]) -> String? {
    guard !shims.isEmpty else { return nil }
    let names = ListFormatter.localizedString(byJoining: shims.map(\.lastPathComponent))
    return shims.count == 1
        ? String(localized: "Command: \(names)")
        : String(localized: "Commands: \(names)")
}

private struct StandaloneToolRow: View {
    let tool: StandaloneCommandLineTool
    @Binding var isSelected: Bool

    @State private var isContextMenuActive = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.actionPrimary)
                .allowsHitTesting(false)

            Image(systemName: "terminal")
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(displayDirectoryPath(for: tool.folder))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let commands = commandsLine(tool.install.shims) {
                    Text(commands)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                ForEach(tool.install.launchAgents, id: \.label) { job in
                    Text("Runs in the background: \(job.label)")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.statusCheckText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            Text(formatBytes(tool.sizeBytes))
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
        .modifier(ToolRowCard(isMenuActive: isContextMenuActive))
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
        .finderRevealMenu(isMenuActive: $isContextMenuActive) {
            [ScanRowLocation(url: tool.folder, sizeBytes: tool.sizeBytes)]
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.12), value: isContextMenuActive)
    }
}

private struct ManagedToolRow: View {
    let tool: PackageManagerTool
    let onUninstall: () -> Void

    @State private var isContextMenuActive = false

    private var detail: String {
        [tool.manager.displayName, tool.context].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: "shippingbox")
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            Text(formatBytes(tool.sizeBytes))
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()

            Button(String(localized: "Uninstall…"), action: onUninstall)
                .buttonStyle(.purge(.secondary, size: .small))
                .accessibilityLabel(String(localized: "Uninstall \(tool.name) with \(tool.manager.displayName)"))
        }
        .modifier(ToolRowCard(isMenuActive: isContextMenuActive))
        .finderRevealMenu(isMenuActive: $isContextMenuActive) {
            tool.locations.map { ScanRowLocation(url: $0) }
        }
        .animation(.easeOut(duration: 0.12), value: isContextMenuActive)
    }
}

// MARK: - Removal sheet

/// The confirm for standalone installs: every path that moves, the settings
/// that go with each folder, what stays, and the background jobs Purge stops
/// first. When Purge refuses, the sheet stays open and says why.
struct CommandLineToolReviewSheet: View {
    let plan: CommandLineToolRemovalPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    static let settingsShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    ForEach(plan.tools) { tool in
                        toolCard(tool)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240)

            if let refusal = plan.refusal {
                refusalNote(refusal)
            }

            footer
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 600, minHeight: 520)
        .background(AppColors.surfaceBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text(plan.tools.count == 1
                 ? String(localized: "Remove \(plan.tools[0].name)?")
                 : String(localized: "Remove \(plan.tools.count) command-line tools?"))
                .font(AppStyle.Typography.pageTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("Each tool's folder and the commands that start it move to the Trash, so you can put them back until you empty it. The folder can hold settings, keys and history, and they go with it. Purge first checks that nothing is using these files.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolCard(_ tool: StandaloneCommandLineTool) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            HStack {
                Text(tool.name)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text(formatBytes(tool.sizeBytes))
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
            ForEach(tool.install.removalPaths, id: \.self) { url in
                Text(displayDirectoryPath(for: url))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !tool.settingsFiles.isEmpty {
                Text(settingsLine(tool.settingsFiles))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tool.install.launchAgents, id: \.label) { job in
                Text("Purge stops the background job \(job.label) first.")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tool.install.kept.isEmpty {
                let kept = ListFormatter.localizedString(byJoining: tool.install.kept.map { displayDirectoryPath(for: $0) })
                Text("Stays: \(kept)")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private func settingsLine(_ files: [String]) -> String {
        let shown = Array(files.prefix(Self.settingsShown))
        let list = ListFormatter.localizedString(byJoining: shown)
        let more = files.count - shown.count
        return more > 0
            ? String(localized: "Your settings go too: \(list) and \(more) more")
            : String(localized: "Your settings go too: \(list)")
    }

    private func refusalNote(_ text: String) -> some View {
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
            Text("Freeing \(formatBytes(plan.totalBytes))")
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.purge(.secondary))
                .keyboardShortcut(.cancelAction)
                .disabled(plan.isChecking)

            Button(action: onConfirm) {
                CleaningButtonLabel(
                    title: plan.isChecking
                        ? String(localized: "Checking...")
                        : (plan.refusal == nil
                            ? String(localized: "Move \(plan.pathCount) to Trash")
                            : String(localized: "Try Again")),
                    systemImage: nil,
                    isCleaning: plan.isChecking
                )
            }
            .buttonStyle(.purge(.destructive))
            .keyboardShortcut(.defaultAction)
            .disabled(plan.isChecking)
        }
    }
}

// MARK: - Package-manager sheet

/// The confirm for a tool a package manager owns: the exact command Purge
/// runs, that the manager deletes it permanently, and the manager's own words
/// if it refuses.
struct PackageManagerHandoffSheet: View {
    let handoff: PackageManagerHandoff
    let onCancel: () -> Void
    let onRun: () -> Void

    private var tool: PackageManagerTool { handoff.tool }
    private var isRunning: Bool { handoff.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text("Uninstall \(tool.name) with \(tool.manager.displayName)?")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("\(tool.manager.displayName) installed \(tool.name), so it removes it, with its own checks and records. It deletes \(tool.name) permanently. It isn't moved to the Trash.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            commandBox

            if case .failed(let message) = handoff.state {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    Text("\(tool.manager.displayName) didn't remove it:")
                        .font(AppStyle.Typography.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(message)
                        .font(AppStyle.Typography.metadata.monospaced())
                        .foregroundStyle(AppColors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppStyle.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                        .fill(AppColors.statusDangerFill)
                )
            } else if !tool.canRun {
                Text("Purge couldn't find \(tool.manager.displayName) on this Mac. Copy the command and run it in Terminal.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: AppStyle.Spacing.small) {
                Text("Frees \(formatBytes(tool.sizeBytes))")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button(String(localized: "Copy Command")) {
                    FinderReveal.copyText(tool.command)
                }
                .buttonStyle(.purge(.quiet))
                Button(String(localized: "Cancel"), action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                if tool.canRun {
                    Button(action: onRun) {
                        CleaningButtonLabel(
                            title: isRunning ? String(localized: "Uninstalling...") : String(localized: "Uninstall"),
                            systemImage: nil,
                            isCleaning: isRunning
                        )
                    }
                    .buttonStyle(.purge(.destructive))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
                }
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 560)
        .frame(minHeight: 300)
        .background(AppColors.surfaceBase)
        .interactiveDismissDisabled(isRunning)
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            Text(tool.command)
                .font(AppStyle.Typography.callout.monospaced())
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
            if let context = tool.context {
                Text("Runs with \(context)")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .fill(AppColors.fillSecondary)
        )
    }
}
