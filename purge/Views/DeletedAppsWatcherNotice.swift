import SwiftUI

/// Sidebar card shown while deleted-app reviews are on but the background watcher
/// is blocked or not running. Without it the feature fails in silence: an app goes
/// to the Trash, nothing happens, and the user has no way to learn why. It sits in
/// the sidebar so it is on every tab, and stays until the problem is fixed or the
/// feature is turned off.
struct DeletedAppsWatcherNotice: View {
    @ObservedObject private var monitor = RemovedAppMonitor.shared

    var body: some View {
        DeletedAppsWatcherNoticeCard(
            health: monitor.watcherHealth,
            isRestarting: monitor.isRestartingWatcher,
            onFix: { monitor.fixWatcher() },
            onTurnOff: { monitor.setEnabled(false) }
        )
    }
}

struct DeletedAppsWatcherNoticeCard: View {
    let health: WatcherHealth
    let isRestarting: Bool
    let onFix: () -> Void
    let onTurnOff: () -> Void

    private enum NoticeFont {
        static let title = AppStyle.Typography.callout.weight(.semibold)
        static let body = AppStyle.Typography.metadataEmphasis
    }

    var body: some View {
        if health.needsAttention, let message = health.shortMessage, let fixTitle = health.fixTitle {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.statusCheckText)
                        .accessibilityHidden(true)

                    Text(WatcherHealth.problemTitle)
                        .font(NoticeFont.title)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(LocalizedStringKey(message))
                    .font(NoticeFont.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppStyle.Spacing.xxSmall)

                // Full width, like the Clean button below it: "Open System Settings"
                // does not fit beside a second button at sidebar width.
                Button(action: onFix) {
                    CleaningButtonLabel(
                        title: isRestarting ? "Restarting…" : fixTitle,
                        systemImage: nil,
                        isCleaning: isRestarting
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.purge(.primary))
                .disabled(isRestarting)
                .padding(.top, AppStyle.Spacing.small)

                Button("Turn Off", action: onTurnOff)
                    .buttonStyle(.purge(.quiet, size: .small))
                    .frame(maxWidth: .infinity)
                    .padding(.top, AppStyle.Spacing.xxSmall)
                    .help("Stop reviewing leftovers when an app is deleted")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppStyle.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .fill(AppColors.fillSecondary)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .strokeBorder(AppColors.statusCheckText.opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        }
    }
}
