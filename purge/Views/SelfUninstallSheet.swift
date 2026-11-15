import AppKit
import SwiftUI

/// Uninstall Purge (#330). Turns off what Purge runs in the background, moves
/// Purge to the Trash, and quits.
///
/// Each state is a title, at most one short line, the list and the buttons. The
/// list says what happens; nothing in it is a control, so its rows carry an
/// icon and a status instead of anything that looks like a switch.
struct SelfUninstallSheet: View {
    @ObservedObject var store: PurgeStore
    @StateObject private var model: SelfUninstaller
    /// Read once: whether the done screen should point to Full Disk Access.
    private let hadFullDiskAccess: Bool

    /// `model` has usually loaded already (`PurgeStore.openSelfUninstall`), so
    /// the sheet opens at its final size; one that has not is read here.
    init(store: PurgeStore, model: SelfUninstaller, hadFullDiskAccess: Bool) {
        self.store = store
        _model = StateObject(wrappedValue: model)
        self.hadFullDiskAccess = hadFullDiskAccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            content
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 460, alignment: .leading)
        .background(AppColors.surfaceBase)
        // Once Purge is in the Trash every way out quits, so the sheet never
        // leaves a running copy behind in the Trash.
        .interactiveDismissDisabled()
        .task {
            guard model.phase == .reading else { return }
            await model.load()
        }
        // No animation on the whole sheet: the sheet resizes between states,
        // and animating its content as well made the rows jump. Each row
        // animates only its own status.
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            SelfUninstallHero(icon: .app, title: String(localized: "Uninstall Purge?"))
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            buttons {
                Spacer()
                cancelButton
            }
        case .confirm:
            confirm
        case .working:
            SelfUninstallHero(icon: .app, title: String(localized: "Uninstalling Purge"))
            stepList
            buttons {
                Spacer()
                Button(model.isStopping ? String(localized: "Stopping…") : String(localized: "Cancel")) {
                    model.requestStop()
                }
                .buttonStyle(.purge(.secondary))
                .disabled(model.isStopping || model.hasStartedMoving)
            }
        case .stepFailed:
            SelfUninstallHero(icon: .failed, title: failureTitle, subtitle: String(localized: "Purge wasn’t moved."))
            stepList
            buttons {
                if model.dataIsSplit || model.failedSteps.allSatisfy({ $0.kind != .data }) {
                    Button(String(localized: "Uninstall Anyway")) {
                        Task { await model.uninstallAnyway() }
                    }
                    .buttonStyle(.purge(.quiet))
                }
                Spacer()
                // With data split between here and the Trash, going back to a
                // running Purge would start a new, empty data folder.
                if model.mayCancel { cancelButton }
                Button(String(localized: "Try Again")) {
                    Task { await model.retry() }
                }
                .buttonStyle(.purge(.primary))
                .keyboardShortcut(.defaultAction)
            }
        case .done:
            done
        case .couldNotMove(let problem):
            SelfUninstallHero(
                icon: .warning,
                title: String(localized: "Move Purge to the Trash yourself"),
                subtitle: Self.reason(for: problem)
            )
            buttons {
                Spacer()
                Button(String(localized: "Quit")) { quit() }
                    .buttonStyle(.purge(.secondary))
                Button(String(localized: "Show in Finder and Quit")) { quit(revealingApp: true) }
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Confirm

    @ViewBuilder
    private var confirm: some View {
        SelfUninstallHero(
            icon: .app,
            title: String(localized: "Uninstall Purge?"),
            subtitle: model.partsOn.isEmpty
                ? String(localized: "Moves Purge to the Trash.")
                : String(localized: "Turns these off, then moves Purge to the Trash.")
        )
        if !model.partsOn.isEmpty {
            SelfUninstallFactList {
                ForEach(model.partsOn, id: \.self) { part in
                    SelfUninstallFactRow(symbol: Self.symbol(for: .part(part)), title: Self.title(for: .part(part)))
                }
            }
        }
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
            Toggle(isOn: $model.movesData) {
                Text("Also move settings and history to the Trash")
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .toggleStyle(.checkbox)
            .disabled(!model.mayMoveData)
            if !model.mayMoveData {
                Text("Another copy of Purge is on this Mac, so they stay.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.leading, AppStyle.Spacing.large)
            }
        }
        buttons {
            if store.isReviewingOrCleaning {
                HStack(spacing: AppStyle.Spacing.xxSmallPlus) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the clean")
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.statusCheckText)
                }
            }
            Spacer()
            cancelButton
            Button(String(localized: "Uninstall")) {
                Task { await model.start() }
            }
            .buttonStyle(.purge(.destructive))
            .disabled(store.isReviewingOrCleaning)
        }
    }

    // MARK: Done

    @ViewBuilder
    private var done: some View {
        SelfUninstallHero(
            icon: .done,
            title: String(localized: "Purge is in the Trash"),
            subtitle: model.movedData ? String(localized: "Settings and history too.") : nil
        )
        let stillOn = model.failedSteps
        if !stillOn.isEmpty {
            SelfUninstallFactList {
                ForEach(stillOn) { step in
                    stepRow(step)
                }
            }
        }
        if hadFullDiskAccess {
            HStack(spacing: AppStyle.Spacing.small) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppStyle.Radius.sm))
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                    Text("Full Disk Access")
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Remove Purge from the list in System Settings.")
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(AppStyle.Spacing.small)
            .background(AppColors.fillSecondary, in: RoundedRectangle(cornerRadius: AppStyle.Radius.md))
        }
        buttons {
            Spacer()
            if hadFullDiskAccess {
                Button(String(localized: "Quit Only")) { quit() }
                    .buttonStyle(.purge(.secondary))
                Button(String(localized: "Quit and Open Full Disk Access")) { quit(openingFullDiskAccess: true) }
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "Quit")) { quit() }
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pieces

    private var stepList: some View {
        SelfUninstallFactList {
            ForEach(model.steps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: SelfUninstaller.Step) -> some View {
        SelfUninstallFactRow(
            symbol: Self.symbol(for: step.kind),
            title: Self.title(for: step.kind),
            state: step.state,
            detail: step.state == .failed
                ? (step.kind == .data && model.dataIsSplit
                    ? String(localized: "Some are in the Trash")
                    : Self.failureDetail(for: step.kind))
                : nil,
            fix: step.state == .failed && Self.isListedInLoginItems(step.kind)
                ? (String(localized: "Open Login Items"), { SMAppServiceSettings.openLoginItems() })
                : nil
        )
    }

    private var cancelButton: some View {
        Button(String(localized: "Cancel")) {
            model.dismissed()
            store.selfUninstall = nil
        }
        .buttonStyle(.purge(.secondary))
        .keyboardShortcut(.cancelAction)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            content()
        }
    }

    private var failureTitle: String {
        let failed = model.failedSteps
        guard failed.count == 1, let step = failed.first else {
            return String(localized: "Some parts are still on")
        }
        switch step.kind {
        case .part(let part):
            return String(localized: "Couldn’t turn off \(Self.title(for: .part(part)))")
        case .data:
            return String(localized: "Couldn’t move settings and history")
        case .app:
            return String(localized: "Some parts are still on")
        }
    }

    /// Quits Purge. Opening System Settings or Finder first, so the user lands
    /// there with Purge already gone.
    private func quit(openingFullDiskAccess: Bool = false, revealingApp: Bool = false) {
        if openingFullDiskAccess,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        if revealingApp {
            let running = Bundle.main.bundleURL
            let original = SelfUninstallPolicy.isTranslocated(path: running.path)
                ? SelfUninstallPolicy.originalURL(ofTranslocated: running) ?? running
                : running
            NSWorkspace.shared.activateFileViewerSelecting([original])
        }
        SelfUninstallState.quitClosingSheet { store.selfUninstall = nil }
    }

    // MARK: Words and symbols

    static func title(for kind: SelfUninstaller.StepKind) -> String {
        switch kind {
        case .part(.deletedAppsWatcher): return String(localized: "Deleted-app watcher")
        case .part(.adminHelper): return String(localized: "Admin helper")
        case .part(.finderService): return String(localized: "Finder right-click item")
        case .part(.cleanupReminder): return String(localized: "Cleanup reminder")
        case .part(.loginItem): return String(localized: "Launch at login")
        case .data: return String(localized: "Settings and history")
        case .app: return String(localized: "Move Purge to the Trash")
        }
    }

    static func symbol(for kind: SelfUninstaller.StepKind) -> String {
        switch kind {
        case .part(.deletedAppsWatcher): return "eye"
        case .part(.adminHelper): return "key"
        case .part(.finderService): return "filemenu.and.selection"
        case .part(.cleanupReminder): return "bell"
        case .part(.loginItem): return "power"
        case .data: return "folder"
        case .app: return "trash"
        }
    }

    static func failureDetail(for kind: SelfUninstaller.StepKind) -> String {
        switch kind {
        case .part(.deletedAppsWatcher), .part(.adminHelper), .part(.loginItem):
            return String(localized: "Still in Login Items")
        case .part(.finderService): return String(localized: "Still in Finder’s menu")
        case .part(.cleanupReminder): return String(localized: "Still scheduled")
        case .data: return String(localized: "Nothing moved")
        case .app: return String(localized: "Not moved")
        }
    }

    static func isListedInLoginItems(_ kind: SelfUninstaller.StepKind) -> Bool {
        switch kind {
        case .part(.deletedAppsWatcher), .part(.adminHelper), .part(.loginItem): return true
        case .part(.finderService), .part(.cleanupReminder), .data, .app: return false
        }
    }

    static func reason(for problem: SelfUninstallMoveProblem) -> String {
        switch problem {
        case .readOnlyVolume: return String(localized: "Purge is running from a disk image.")
        case .translocated: return String(localized: "Purge is running from a temporary copy.")
        case .notThisApp: return String(localized: "Purge couldn’t confirm this copy is its own.")
        case .refusedByMacOS: return String(localized: "macOS didn’t let Purge move itself.")
        }
    }
}

/// Opens Login Items in System Settings, where the watcher, the helper and the
/// login item are listed.
private enum SMAppServiceSettings {
    static func openLoginItems() {
        PrivilegedHelperPreferenceStore.shared.openLoginItemsSettings()
    }
}

/// The icon and title at the top of each state.
private struct SelfUninstallHero: View {
    enum Icon {
        case app
        case done
        case failed
        case warning
    }

    let icon: Icon
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            iconView
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .app:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        case .done:
            statusCircle(symbol: "checkmark", text: AppColors.statusSafeText, fill: AppColors.statusSafeFill)
        case .failed:
            statusCircle(symbol: "exclamationmark", text: AppColors.statusDangerText, fill: AppColors.statusDangerFill)
        case .warning:
            statusCircle(symbol: "exclamationmark", text: AppColors.statusCheckText, fill: AppColors.statusCheckFill)
        }
    }

    private func statusCircle(symbol: String, text: Color, fill: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(text)
            }
            .accessibilityHidden(true)
    }
}

/// A quiet panel that holds information rows. Not a list of controls.
private struct SelfUninstallFactList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            content
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.fillSecondary, in: RoundedRectangle(cornerRadius: AppStyle.Radius.md))
    }
}

/// One row: an icon for the part, its name, and while Purge works, its status
/// on the trailing edge.
private struct SelfUninstallFactRow: View {
    let symbol: String
    let title: String
    var state: SelfUninstaller.StepState?
    var detail: String?
    var fix: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(title)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(isActive ? AppColors.textPrimary : AppColors.textSecondary)
                if let detail {
                    Text(detail)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.statusDangerText)
                }
            }
            Spacer(minLength: AppStyle.Spacing.xSmall)
            if let fix {
                Button(fix.title, action: fix.run)
                    .buttonStyle(.purge(.quiet, size: .small))
            }
            statusView
                .frame(width: 16, height: 16)
                .animation(.easeInOut(duration: 0.15), value: state)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityStatus)
    }

    private var isActive: Bool {
        switch state {
        case .working, .done, .failed: return true
        case .pending, .skipped, nil: return false
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .working:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.statusSafeText)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.statusDangerText)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.textTertiary)
        case .pending, nil:
            Color.clear
        }
    }

    private var accessibilityStatus: String {
        switch state {
        case .working: return String(localized: "In progress")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Still on")
        case .skipped: return String(localized: "Not done")
        case .pending, nil: return ""
        }
    }
}
