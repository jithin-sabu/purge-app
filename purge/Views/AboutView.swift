import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var updater: PurgeUpdater
    @AppStorage(FirstRunGate.onboardingCompletedKey) private var hasCompletedOnboarding = false
    @AppStorage(DeveloperMode.userDefaultsKey) private var developerModeEnabled = false
    /// Counts rapid taps on the app icon; reaching the threshold toggles developer mode.
    @State private var iconTapCount = 0
    @State private var devModeFlash: String? = nil
    var showsPageHeader = true
    /// When true, the parent owns scrolling and the macOS 26 progressive scroll-edge blur.
    var usesExternalScrollContainer = false

    var body: some View {
        Group {
            if usesExternalScrollContainer {
                aboutScrollContent
            } else {
                VStack(spacing: 0) {
                    if showsPageHeader {
                        AppSectionPageHeader(title: String(localized: "About"))
                    }

                    ScrollView {
                        aboutScrollContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppColors.surfaceBase)
    }

    private var aboutScrollContent: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
            appIdentitySection
            lifetimeStatsSection
            actionCardSection
            footerSection
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, scrollContentTopPadding)
        .padding(.bottom, AppDetailPageLayout.verticalPadding)
    }

    private var scrollContentTopPadding: CGFloat {
        if usesExternalScrollContainer {
            // macOS 26 reserves this clearance inside the scroll-edge bar instead, so that
            // content scrolling up dissolves below the title rather than at its baseline.
            if #available(macOS 26.0, *) { return 0 }
            return AppDetailPageLayout.clearanceBelowHeader
        }
        return showsPageHeader ? AppStyle.Spacing.medium : AppDetailPageLayout.topContentInset
    }

    private var appIdentitySection: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { registerIconTap() }

            Text("Purge")
                .font(AppStyle.Typography.title)

            if let devModeFlash {
                Text(devModeFlash)
                    .font(AppStyle.Typography.callout.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text(figures: String(localized: "Version \(appVersion)"), style: AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
            }

            aboutCard {
                if let version = updater.readyUpdateVersion {
                    AboutActionRow(
                        icon: "arrow.clockwise",
                        label: PurgeUpdater.restartTitle(forVersion: version)
                    ) {
                        updater.restartToUpdate()
                    }
                } else {
                    AboutActionRow(
                        icon: "arrow.triangle.2.circlepath",
                        label: String(localized: "Check for updates"),
                        isEnabled: updater.canCheckForUpdates
                    ) {
                        updater.checkForUpdates()
                    }
                }
            }
            .padding(.top, AppStyle.Spacing.xxSmallPlus)
        }
        .frame(maxWidth: .infinity)
    }

    /// Counts taps on the app icon; the threshold toggles hidden developer mode.
    private func registerIconTap() {
        iconTapCount += 1
        guard iconTapCount >= DeveloperMode.unlockTapCount else { return }
        iconTapCount = 0
        developerModeEnabled.toggle()
        devModeFlash = developerModeEnabled
            ? String(localized: "Developer mode enabled")
            : String(localized: "Developer mode disabled")
        let message = devModeFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if devModeFlash == message { devModeFlash = nil }
        }
    }

    private var lifetimeStatsSection: some View {
        aboutCard {
            VStack(spacing: AppStyle.Spacing.xSmall) {
                if showsLifetimeStatsPlaceholder {
                    lifetimeStatsPlaceholder
                } else {
                    lifetimeStatsContent
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppStyle.Spacing.medium)
            .padding(.vertical, AppStyle.Spacing.medium)
        }
    }

    private var showsLifetimeStatsPlaceholder: Bool {
        !store.hasDisplayableLifetimeStats
    }

    private var lifetimeStatsPlaceholder: some View {
        VStack(spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "externaldrive.badge.minus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppColors.textTertiary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Nothing cleaned yet")
                .font(AppStyle.Typography.title)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Nothing cleaned yet")

            Text("Run your first scan to get started")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, AppStyle.Spacing.xxSmall)
    }

    private var lifetimeStatsContent: some View {
        VStack(spacing: AppStyle.Spacing.xSmall) {
            Text("Lifetime moved to trash")
                .font(AppStyle.Typography.metadata.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)

            Text(formatBytes(store.totalMovedToTrashBytes))
                .font(AppStyle.Typography.displaySmall.numbers)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .accessibilityLabel("Lifetime moved to trash, \(formatBytes(store.totalMovedToTrashBytes))")

            if let comparisonItem = LifetimeSizeComparison.item(for: store.totalMovedToTrashBytes) {
                LifetimeSizeComparisonChip(item: comparisonItem)
                    .padding(.top, AppStyle.Spacing.xxSmall)
            }
        }
    }

    private var actionCardSection: some View {
        aboutCard {
            VStack(spacing: 0) {
                AboutAllowlistSummaryBlock()

                AboutActionRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: String(localized: "View the full allowlist")
                ) {
                    NSWorkspace.shared.open(Self.allowlistPolicyURL)
                }

                InsetCardDivider()

                AboutActionRow(icon: "ant.fill", label: String(localized: "Report a bug")) {
                    NSWorkspace.shared.open(reportBugURL)
                }

                InsetCardDivider()

                AboutActionRow(icon: "lightbulb.fill", label: String(localized: "Request a feature")) {
                    NSWorkspace.shared.open(featureRequestURL)
                }

                InsetCardDivider()

                AboutActionRow(icon: "arrow.counterclockwise", label: String(localized: "Replay onboarding")) {
                    hasCompletedOnboarding = false
                }

                InsetCardDivider()

                AboutActionRow(icon: "cup.and.saucer.fill", label: String(localized: "Buy me a coffee")) {
                    // Counts as having seen the ask, so cleanups stop mentioning it.
                    SupportNudge.recordLinkOpened()
                    NSWorkspace.shared.open(SupportNudge.url)
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: AppStyle.Spacing.xxSmallPlus) {
            HStack(spacing: AppStyle.Spacing.xxSmall) {
                Text("Made with")
                    .foregroundStyle(AppColors.textSecondary)
                Image(systemName: "heart.fill")
                    .foregroundStyle(AppColors.statusDangerText)
                Text("by")
                    .foregroundStyle(AppColors.textSecondary)
                Button {
                    NSWorkspace.shared.open(xProfileURL)
                } label: {
                    Text("Jithin")
                        .fontWeight(.medium)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jithin on X")
            }
            .font(AppStyle.Typography.metadata)

            Text(figures: footerVersionText, style: AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppStyle.Spacing.large)
        .padding(.bottom, AppStyle.Spacing.xSmall)
    }

    private var footerVersionText: String {
        guard let buildDate = bundleReleaseDate else {
            return String(localized: "Version \(appVersion)")
        }
        return String(localized: "Version \(appVersion) · \(Self.buildDateFormatter.string(from: buildDate))")
    }

    private func aboutCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppColors.fillSecondary,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)) where build != version:
            return String(localized: "\(version) (\(build))")
        case let (.some(version), _):
            return version
        case let (_, .some(build)):
            return build
        default:
            return "1.0.0"
        }
    }

    private var bundleReleaseDate: Date? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return date
    }

    private static let buildDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        if Locale.current.language.languageCode?.identifier == "en" {
            formatter.dateFormat = "d MMM yyyy"
            formatter.locale = Locale(identifier: "en_GB")
        } else {
            formatter.dateStyle = .medium
        }
        return formatter
    }()

    private var reportBugURL: URL {
        URL(string: "mailto:jithin@purgemac.com?subject=Purge%20Bug%20Report")!
    }

    private var featureRequestURL: URL {
        URL(string: "mailto:jithin@purgemac.com?subject=Purge%20Feature%20Request")!
    }

    private var xProfileURL: URL {
        URL(string: "https://x.com/sabu_jithin")!
    }

    static let repoBaseURL = URL(string: "https://github.com/jithin-sabu/purge-app")!

    static var allowlistPolicyURL: URL {
        allowlistPolicyURL(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// The policy as the installed version has it, not as `main` has it now (#191).
    /// Releases are tagged `v<version>`. A version that is not plain numbers and
    /// dots has no tag, so it gets `main`.
    static func allowlistPolicyURL(version: String?) -> URL {
        let ref: String
        if let version, !version.isEmpty, version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            ref = "v\(version)"
        } else {
            ref = "main"
        }
        return URL(string: "\(repoBaseURL.absoluteString)/blob/\(ref)/purge/Services/DeletionSafetyPolicy.swift")!
    }
}

private struct LifetimeSizeComparisonChip: View {
    let item: OnboardingSizeComparisonItem

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xxSmallPlus) {
            Image(systemName: item.symbol)
                .imageScale(.small)
                .accessibilityHidden(true)

            Text("That's room for \(item.displayLabel)")
                .lineLimit(1)
        }
        .font(AppStyle.Typography.rowTitle)
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.xxSmallPlus)
        .background {
            Capsule(style: .continuous)
                .fill(AppColors.fillSecondary)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(AppColors.borderStrong, lineWidth: 1)
        }
        .accessibilityLabel("That's room for \(item.displayLabel)")
    }
}

private struct AboutAllowlistSummaryBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text("what purge can clean")
                .font(AppStyle.Typography.metadata.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                ForEach(SafetyAllowlistSummary.allowedCategories) { category in
                    AboutAllowlistCategoryRow(category: category)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(SafetyAllowlistSummary.boundaryLine)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppStyle.Spacing.medium)
        .padding(.vertical, AppStyle.Spacing.medium)
    }
}

private struct AboutAllowlistCategoryRow: View {
    let category: SafetyAllowlistSummary.Category

    var body: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
            Image(systemName: category.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 16, height: 16, alignment: .center)

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(category.title)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(category.description)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.title). \(category.description)")
    }
}

private struct AboutActionRow: View {
    let icon: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppStyle.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 16)

                Text(LocalizedStringKey(label))
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(width: 12)
            }
            .padding(.horizontal, AppStyle.Spacing.medium)
            .frame(height: AppStyle.Row.compactHeight)
            .contentShape(Rectangle())
            // The plain style doesn't dim a disabled row on its own.
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
