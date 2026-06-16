import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var store: PurgeStore
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var fundingStore = FundingStore()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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
                        AppSectionPageHeader(title: "About")
                    }

                    ScrollView {
                        aboutScrollContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppStyle.canvas)
    }

    private var aboutScrollContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            appIdentitySection
            lifetimeStatsSection
            fundingSection
            actionCardSection
            footerSection
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, alignment: .center)
        .task {
            await fundingStore.refresh()
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(
            .top,
            usesExternalScrollContainer
                ? AppDetailPageLayout.scrollEdgeClearanceBelowHeader
                : (showsPageHeader ? AppStyle.Spacing.medium : AppDetailPageLayout.topContentInset)
        )
        .padding(.bottom, AppDetailPageLayout.verticalPadding)
    }

    private var appIdentitySection: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())

            Text("Purge")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            Text("Version \(appVersion)")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            aboutCard {
                AboutUpdateRow(checker: updateChecker)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var lifetimeStatsSection: some View {
        aboutCard {
            VStack(spacing: 8) {
                if showsLifetimeStatsPlaceholder {
                    lifetimeStatsPlaceholder
                } else {
                    lifetimeStatsContent
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var showsLifetimeStatsPlaceholder: Bool {
        !store.hasDisplayableLifetimeStats
    }

    private var lifetimeStatsPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.minus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Nothing cleaned yet")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Nothing cleaned yet")

            Text("Run your first scan to get started")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 4)
    }

    private var lifetimeStatsContent: some View {
        VStack(spacing: 8) {
            Text("Lifetime cleaned")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)

            Text(formatBytes(store.totalRecoveredBytes))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .accessibilityLabel("Lifetime cleaned, \(formatBytes(store.totalRecoveredBytes))")

            if let comparisonItem = LifetimeSizeComparison.item(for: store.totalRecoveredBytes) {
                LifetimeSizeComparisonChip(item: comparisonItem)
                    .padding(.top, 4)
            }
        }
    }

    private var fundingSection: some View {
        aboutCard {
            VStack(alignment: .leading, spacing: 10) {
                if fundingStore.isComplete {
                    HStack(alignment: .top, spacing: 8) {
                        Text("thanks to everyone who chipped in. purge is signed now.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppStyle.safe)
                            .accessibilityHidden(true)
                    }
                } else {
                    Text("Help get Purge signed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("Purge is free and always will be. If it has earned a spot on your Mac, chip in toward the Apple Developer Fee and help drop the 'unidentified developer' warning.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    fundingProgressBar

                    HStack(alignment: .center, spacing: 8) {
                        Text(fundingProgressLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        Spacer(minLength: 0)

                        Button {
                            if let url = fundingPaymentURL {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cup.and.saucer.fill")
                                    .font(.system(size: 11, weight: .medium))
                                Text("contribute")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(AppStyle.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppStyle.accent.opacity(0.1), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(AppStyle.accent.opacity(0.22), lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Contribute toward signing Purge")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var fundingProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AppStyle.accent.opacity(0.85))
                    .frame(width: max(0, geo.size.width * fundingStore.progress))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Developer fee progress")
        .accessibilityValue("\(Int(fundingStore.progress * 100)) percent")
    }

    private var fundingProgressLabel: String {
        let base = "$\(Int(fundingStore.info.raised)) of $99 (first year)"
        let count = fundingStore.info.contributorCount
        return "\(base) · \(count) chipped in"
    }

    private var fundingPaymentURL: URL? {
        let raw = fundingStore.info.paymentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty,
           raw != "REPLACE_WITH_PAYMENT_LINK",
           let url = URL(string: raw) {
            return url
        }
        return buyMeACoffeeURL
    }

    private var actionCardSection: some View {
        aboutCard {
            VStack(spacing: 0) {
                AboutActionRow(icon: "ant.fill", label: "Report a bug") {
                    NSWorkspace.shared.open(reportBugURL)
                }

                InsetCardDivider()

                AboutActionRow(icon: "lightbulb.fill", label: "Request a feature") {
                    NSWorkspace.shared.open(featureRequestURL)
                }

                InsetCardDivider()

                AboutActionRow(icon: "arrow.counterclockwise", label: "Replay onboarding") {
                    hasCompletedOnboarding = false
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Made with")
                    .foregroundStyle(.secondary)
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("by")
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(xProfileURL)
                } label: {
                    Text("Jithin")
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jithin on X")
            }
            .font(.subheadline)

            Text(footerVersionText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var footerVersionText: String {
        guard let buildDate = bundleReleaseDate else {
            return "Version \(appVersion)"
        }
        return "Version \(appVersion) · \(Self.buildDateFormatter.string(from: buildDate))"
    }

    private func aboutCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppStyle.elevated,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppStyle.hairline, lineWidth: 0.5)
            }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)) where build != version:
            return "\(version) (\(build))"
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
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    private var reportBugURL: URL {
        URL(string: "mailto:design@jithinsabu.com?subject=Purge%20Bug%20Report")!
    }

    private var featureRequestURL: URL {
        URL(string: "mailto:design@jithinsabu.com?subject=Purge%20Feature%20Request")!
    }

    private var buyMeACoffeeURL: URL {
        URL(string: "https://buymeacoffee.com/jithinsabu")!
    }

    private var xProfileURL: URL {
        URL(string: "https://x.com/sabu_jithin")!
    }
}

private struct LifetimeSizeComparisonChip: View {
    let item: OnboardingSizeComparisonItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol)
                .imageScale(.small)
                .accessibilityHidden(true)

            Text("About the size of \(item.label)")
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityLabel("About the size of \(item.label)")
    }
}

private struct AboutUpdateRow: View {
    @ObservedObject var checker: UpdateChecker

    private let allReleasesURL = URL(string: "https://github.com/jithinsabumec/purge-app/releases")!

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Button {
                Task { await checker.check() }
            } label: {
                statusLabel
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(checker.status == .checking)

            trailingContent
        }
        .padding(.horizontal, 16)
        .frame(height: AppStyle.Row.compactHeight)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch checker.status {
        case .idle:
            Text("Check for updates")
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("checking...")
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let current):
            Text("you're up to date (v\(current))")
        case .updateAvailable(let latest, _):
            Text("update available: v\(latest)")
        case .failed:
            Text("couldn't check")
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch checker.status {
        case .updateAvailable(_, let url):
            Button("view release") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        case .failed:
            Button("view releases") {
                NSWorkspace.shared.open(allReleasesURL)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        case .checking:
            EmptyView()
        default:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
    }
}

private struct AboutActionRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .padding(.horizontal, 16)
            .frame(height: AppStyle.Row.compactHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
