import SwiftUI

// The main window's cues while Full Disk Access is off. Every one reads the store's
// single `hasFullDiskAccess` value and opens the same `LookDeeperSheet`, so none of
// them can go stale or ask in its own words.

/// Stands in for a tab that cannot work without Full Disk Access.
struct LockedFeatureView: View {
    enum Feature {
        case largeFiles
        case uninstaller

        var title: String {
            switch self {
            case .largeFiles: return "Large Files needs a look inside your folders"
            case .uninstaller: return "The uninstaller needs full access"
            }
        }

        var message: String {
            switch self {
            case .largeFiles:
                return "Big files tend to live in Downloads, Documents and Desktop, and macOS keeps those locked until you say Purge can look. Purge only ever shows them to you. It never cleans them on its own."
            case .uninstaller:
                return "Apps leave settings and caches in folders macOS keeps locked. Without access, Purge would remove the app and leave all of that behind, so it waits until it can do the whole job."
            }
        }

        var symbol: String {
            switch self {
            case .largeFiles: return "doc.viewfinder"
            case .uninstaller: return "shippingbox"
            }
        }
    }

    let feature: Feature
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        VStack(spacing: AppStyle.Spacing.medium) {
            Image(systemName: feature.symbol)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)

            VStack(spacing: AppStyle.Spacing.xSmall) {
                Text(feature.title)
                    .font(AppStyle.Typography.sectionTitle)
                    .multilineTextAlignment(.center)

                Text(feature.message)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.isLookDeeperPresented = true
            } label: {
                Label("Look deeper", systemImage: "lock.open")
            }
            .buttonStyle(.purge(.primary))
        }
        .frame(maxWidth: 440)
        .padding(AppStyle.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Sits beside Scan on App Caches and Dev Tools, where the list is real but partial.
struct LookDeeperHeaderButton: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        Button {
            store.isLookDeeperPresented = true
        } label: {
            Label("Look deeper", systemImage: "lock.open")
        }
        .buttonStyle(.purge(.secondary))
        .help("Some places are still locked. Let Purge look deeper.")
    }
}

/// A slim tappable card in the sidebar, on every tab, until access is granted. The
/// whole card is the button, like the suggestion rows at the top of System Settings,
/// so it reads as "there when you're ready" rather than a warning.
struct LimitedScanNotice: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        Button {
            store.isLookDeeperPresented = true
        } label: {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: "lock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Limited scan")
                        .font(AppStyle.Typography.callout.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Let Purge look deeper")
                        .font(AppStyle.Typography.metadataEmphasis)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.vertical, AppStyle.Spacing.xSmall + 2)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .fill(AppColors.fillSecondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous))
        }
        .buttonStyle(LimitedScanNoticeButtonStyle())
        .accessibilityLabel("Limited scan. Let Purge look deeper.")
        .transition(.opacity)
    }
}

private struct LimitedScanNoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
