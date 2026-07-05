import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var store: PurgeStore
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var fundingStore = FundingStore()
    @State private var isRefreshingFunding = false
    @State private var fundingRefreshRotation = 0.0
    /// Ephemeral line shown in place of the stats line right after a user refresh.
    @State private var flashMessage: String? = nil
    /// The previously displayed total; also drives the progress bar so it can
    /// animate from the old amount to the freshly fetched one. nil until first load.
    @State private var previousFundingTotal: Double? = nil
    /// Last flash line shown, so we never repeat the same one twice in a row.
    @State private var lastFlash: String? = nil
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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
        .background(AppColors.bgBase)
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
            // Seed the displayed total on first load. No flash message here —
            // ephemeral feedback only fires on an explicit user refresh.
            previousFundingTotal = fundingStore.info.raised
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
                .onTapGesture { registerIconTap() }

            Text("Purge")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            if let devModeFlash {
                Text(devModeFlash)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Version \(appVersion)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            aboutCard {
                AboutUpdateRow(checker: updateChecker)
            }
            .padding(.top, 6)
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
            ? "Developer mode enabled"
            : "Developer mode disabled"
        let message = devModeFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if devModeFlash == message { devModeFlash = nil }
        }
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
                            .foregroundStyle(AppColors.tagSafeText)
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
                        // Same font/size/slot as the stats line so swapping in a
                        // flash message is a soft content fade, never a layout jump.
                        Text(flashMessage ?? fundingProgressLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .contentTransition(.opacity)

                        Button {
                            refreshFunding()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(fundingRefreshRotation))
                                .task(id: isRefreshingFunding) {
                                    // Spin with a chain of finite turns while
                                    // refreshing. When the fetch finishes,
                                    // isRefreshingFunding flips and this task is
                                    // cancelled, so the spin stops cleanly —
                                    // unlike repeatForever, which never halts.
                                    guard isRefreshingFunding else { return }
                                    while isRefreshingFunding && !Task.isCancelled {
                                        withAnimation(.linear(duration: 0.8)) {
                                            fundingRefreshRotation += 360
                                        }
                                        try? await Task.sleep(nanoseconds: 800_000_000)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshingFunding)
                        .accessibilityLabel("Refresh amount raised")

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
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppColors.bgElevated, in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
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
                    .fill(AppColors.textPrimary.opacity(0.85))
                    .frame(width: max(0, geo.size.width * fundingFraction))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Developer fee progress")
        .accessibilityValue("\(Int(fundingFraction * 100)) percent")
    }

    /// Progress fraction driven by the locally displayed total so the bar can
    /// animate from the previous amount to a freshly fetched one on refresh.
    private var fundingFraction: Double {
        let goal = fundingStore.info.goal
        let raised = previousFundingTotal ?? fundingStore.info.raised
        return goal <= 0 ? 1 : min(max(raised / goal, 0), 1)
    }

    private func refreshFunding() {
        guard !isRefreshingFunding else { return }
        isRefreshingFunding = true
        let previous = previousFundingTotal ?? fundingStore.info.raised
        Task {
            let succeeded = await fundingStore.refresh()
            let newTotal = fundingStore.info.raised
            let goal = fundingStore.info.goal

            let line = fundingFlashLine(
                previous: previous,
                new: newTotal,
                goal: goal,
                succeeded: succeeded
            )

            // Animate the bar to the fetched amount (stay put if the fetch failed).
            withAnimation(.easeInOut(duration: 0.6)) {
                previousFundingTotal = succeeded ? newTotal : previous
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                flashMessage = line
            }
            isRefreshingFunding = false

            // Hold the line briefly, then fade back to the normal stats.
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                flashMessage = nil
            }
        }
    }

    /// Picks a casual one-liner for the refresh outcome, never repeating the
    /// previous line back to back. Templated lines interpolate the live numbers.
    private func fundingFlashLine(
        previous: Double,
        new: Double,
        goal: Double,
        succeeded: Bool
    ) -> String {
        let delta = Int(new - previous)
        let total = Int(new)
        let goalInt = Int(goal)

        let pool: [String]
        if !succeeded {
            pool = [
                "couldn't reach the jar. give it another tap",
                "hmm, no signal. try again in a sec"
            ]
        } else if previous < goal && new >= goal {
            pool = [
                "we made it. purge is getting signed",
                "$\(goalInt) reached. bye bye, scary warning",
                "fully funded. you legends pulled it off"
            ]
        } else if new > previous {
            pool = [
                "nice, someone just chipped in",
                "the jar grew. thank you, kind stranger",
                "another one chipped in. getting closer",
                "ka-ching. you love to see it",
                "+$\(delta) closer to signed",
                "that's $\(total) of $\(goalInt) now. onwards"
            ]
        } else {
            pool = [
                "no change yet, and that's totally fine",
                "still $\(total). the jar's patient",
                "all quiet for now. purge stays free either way",
                "nothing new this time, no rush at all",
                "holding steady. thanks for checking in"
            ]
        }

        let candidates = pool.count > 1 ? pool.filter { $0 != lastFlash } : pool
        let pick = candidates.randomElement() ?? pool[0]
        lastFlash = pick
        return pick
    }

    private var fundingProgressLabel: String {
        let base = "$\(Int(fundingStore.info.raised)) of $99"
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
                AppColors.bgElevated,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
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

    private let allReleasesURL = URL(string: "https://github.com/jithin-sabu/purge-app/releases")!

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
