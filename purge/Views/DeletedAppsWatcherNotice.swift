import SwiftUI

/// Sidebar row shown while deleted-app reviews are on but the background watcher
/// is blocked or not running. Without it the feature fails in silence: an app goes
/// to the Trash, nothing happens, and the user has no way to learn why. It sits in
/// the sidebar so it is on every tab, and stays until the problem is fixed or the
/// feature is turned off. The row only names the problem; the sheet it opens
/// explains it and holds the fix, so the sidebar carries no main action of its own.
struct DeletedAppsWatcherNotice: View {
    @ObservedObject private var monitor = RemovedAppMonitor.shared

    var body: some View {
        // The presenter is created and destroyed with the problem, so its sheet
        // state never outlives it: a fixed watcher closes an open sheet, and the
        // next problem starts with the sheet closed.
        if monitor.watcherHealth.needsAttention {
            DeletedAppsWatcherNoticePresenter(monitor: monitor)
        }
    }
}

private struct DeletedAppsWatcherNoticePresenter: View {
    @ObservedObject var monitor: RemovedAppMonitor
    @State private var isSheetPresented = false

    var body: some View {
        DeletedAppsWatcherNoticeRow(
            health: monitor.watcherHealth,
            onOpen: { isSheetPresented = true }
        )
        .sheet(isPresented: $isSheetPresented) {
            DeletedAppsWatcherSheet(
                health: monitor.watcherHealth,
                isRestarting: monitor.isRestartingWatcher,
                onFix: {
                    monitor.fixWatcher()
                    // System Settings takes over from here. A restart keeps the
                    // sheet open to show its progress; success closes it with the row.
                    if monitor.watcherHealth == .needsApproval { isSheetPresented = false }
                },
                onTurnOff: {
                    isSheetPresented = false
                    monitor.setEnabled(false)
                },
                onClose: { isSheetPresented = false }
            )
        }
    }
}

struct DeletedAppsWatcherNoticeRow: View {
    let health: WatcherHealth
    let onOpen: () -> Void

    var body: some View {
        if let hint = health.shortHint {
            SidebarNoticeRow(
                systemImage: "exclamationmark.triangle.fill",
                iconColor: AppColors.statusCheckText,
                title: WatcherHealth.shortTitle,
                subtitle: hint,
                accessibilityLabel: "\(WatcherHealth.problemTitle). \(hint)",
                action: onOpen
            )
        }
    }
}

/// The explanation and the one fix for the current problem, opened from the row.
struct DeletedAppsWatcherSheet: View {
    let health: WatcherHealth
    let isRestarting: Bool
    let onFix: () -> Void
    let onTurnOff: () -> Void
    let onClose: () -> Void

    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(WatcherHealth.problemTitle)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                if let message = health.problemMessage {
                    Text(LocalizedStringKey(message))
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: AppStyle.Spacing.small) {
                Button("Turn Off", action: onTurnOff)
                    .buttonStyle(.purge(.quiet))
                    .fixedSize()
                    .help("Stop reviewing leftovers when an app is deleted")

                Spacer()

                Button("Not Now", action: onClose)
                    .buttonStyle(.purge(.secondary))
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)

                if let fixTitle = health.fixTitle {
                    Button(action: onFix) {
                        CleaningButtonLabel(
                            title: isRestarting ? String(localized: "Restarting…") : fixTitle,
                            systemImage: nil,
                            isCleaning: isRestarting
                        )
                    }
                    .buttonStyle(.purge(.primary))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRestarting)
                }
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: Self.width)
        .background(AppColors.surfaceBase)
    }
}
