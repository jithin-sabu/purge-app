import SwiftUI

// MARK: - Apple Intelligence models

/// Apple Intelligence's on-device models: gigabytes System Settings files under
/// System Data, with no switch on macOS 27 to remove them. Remove releases them
/// through Apple's asset service and blocks the downloads with a profile the
/// user approves once; Download Again lifts the block and asks for them back.
/// Shown only on macOS 27 and only when there is something to say.
struct OverviewAppleIntelligenceRow: View {
    @ObservedObject var store: AppleIntelligenceModelStore
    let linkedState: OverviewLinkedRowState

    @EnvironmentObject private var diskStore: DiskSummaryStore
    /// Set when the confirmation is open. It drives the popover itself, so what
    /// the click removes is fixed when it opens.
    @State private var plan: AppleIntelligenceRemovalPlan?
    @State private var isShowingInfo = false

    /// Not a bar segment, so the bar never highlights it; it only fades with the rest.
    static let id = "appleIntelligenceModels"

    private static let info = String(localized: "Apple Intelligence keeps its models on this Mac, counted under System Data. Remove releases them through Apple's own asset service and installs a profile so macOS doesn't download them again. Download Again removes that profile and asks macOS for them back. The size shown is Apple's figure; macOS already treats part of it as available, so the disk gains less than that.")

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            // Apple's own mark for the feature, as an image: the white loop on its
            // orange, pink, blue and lilac tile. The drawn blends never matched it.
            OverviewIconTile(symbol: nil, color: AppColors.Chart.everythingElse, imageName: "AppleIntelligenceMark")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Apple Intelligence models")
                        .font(AppStyle.Typography.headline)
                    infoButton
                }
                Text(detail)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            trailing
            // Apple's figure, placed and sized like the other rows' figures.
            if let bytes = store.reading?.latestBytes, bytes > 0, store.reading?.isAnythingPresent == true {
                Text(formatStorageBytes(bytes))
                    .font(AppStyle.Typography.sectionTitle)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .accessibilityElement(children: .contain)
        .task { await store.refreshAccounts() }
        // Models arriving after Download Again: re-read so the row shows them landing.
        .task(id: store.isDownloading) {
            guard store.isDownloading else { return }
            while !Task.isCancelled, store.isDownloading {
                try? await Task.sleep(for: .seconds(20))
                await store.refresh()
            }
        }
    }

    private var infoButton: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textTertiary)
        }
        .buttonStyle(.plain)
        .help("What are the Apple Intelligence models?")
        .accessibilityLabel("About the Apple Intelligence models")
        .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                AppleIntelligenceBreakdown(reading: store.reading)
                Text(Self.info)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppStyle.Spacing.medium)
            .frame(width: 400)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if store.isWaitingInSettings {
            Button("Cancel") { store.cancelWaiting() }
                .buttonStyle(.purge(.quiet, size: .small))
        } else if store.isBusy {
            Button {} label: {
                CleaningButtonLabel(title: "Working...", systemImage: nil, isCleaning: true)
            }
            .buttonStyle(.purge(.secondary, size: .small))
            .disabled(true)
        } else if store.reading?.isAnythingPresent == true, !store.isDownloading {
            removeButton
        } else if store.isProfileInstalled || store.reading?.isAnythingPresent == false {
            downloadButton
        }
    }

    private var removeButton: some View {
        Button {
            plan = AppleIntelligenceRemovalPlan(
                bytes: store.reading?.latestBytes,
                sets: store.reading?.present.count ?? 0,
                otherAccounts: store.otherAccounts,
                reading: store.reading
            )
        } label: {
            CleaningButtonLabel(title: "Remove", systemImage: nil, isCleaning: false)
        }
        .buttonStyle(.purge(.secondary, size: .small))
        .help("Remove the models and stop macOS downloading them again")
        .popover(item: $plan, arrowEdge: .bottom) { plan in
            OverviewAppleIntelligenceConfirmation(
                plan: plan,
                onCancel: { self.plan = nil },
                onConfirm: {
                    self.plan = nil
                    Task {
                        await store.remove()
                        diskStore.refresh()
                    }
                }
            )
        }
    }

    private var downloadButton: some View {
        Button("Download Again") {
            Task {
                await store.downloadAgain()
                diskStore.refresh()
            }
        }
        .buttonStyle(.purge(.secondary, size: .small))
        .help("Remove the profile and ask macOS to download the models again")
    }

    private var detail: String {
        switch store.phase {
        case .waitingForProfileInstall:
            return String(localized: "Install the profile in System Settings to continue")
        case .waitingForProfileRemoval:
            return String(localized: "Remove the Purge profile in System Settings to continue")
        case .releasing:
            return String(localized: "Asking macOS to release the models...")
        case .measuring:
            return String(localized: "Checking...")
        case .requestingDownload:
            return String(localized: "Asking macOS to download them again...")
        case .idle:
            break
        }
        switch store.lastOutcome {
        case .removed(_, let shown, let raw):
            if let shown { return String(localized: "Removed, freed \(formatBytes(shown))") }
            if let raw { return String(localized: "Removed, \(formatBytes(raw)) that macOS already counted as available") }
            return String(localized: "Removed")
        case .someLeft(let removed, let left, let reason):
            return String(localized: "Removed \(removed), but \(left) stayed: \(reason)")
        case .profileNotInstalled:
            return String(localized: "The profile wasn't installed, so nothing was removed")
        case .notReady(let reason):
            return reason
        case .downloadRequested:
            if store.isDownloading {
                return String(localized: "Downloading in the background, this much so far")
            }
            return String(localized: "Download requested")
        case .profileStillInstalled:
            return String(localized: "The profile is still installed, so downloads stay blocked")
        case .downloadRequestFailed(let reason):
            return String(localized: "macOS didn't accept the download request: \(reason)")
        case .cancelled:
            return String(localized: "Cancelled")
        case nil:
            break
        }
        guard let reading = store.reading else {
            return store.hasTriedReading ? String(localized: "Couldn't check right now") : String(localized: "Checking...")
        }
        if reading.isAnythingPresent {
            let blocked = store.isProfileInstalled ? String(localized: ", downloads blocked") : ""
            if reading.latestBytes != nil {
                return String(localized: "Apple's figure; the disk gains less when removed") + blocked
            }
            return String(localized: "On this Mac, size unknown") + blocked
        }
        if store.isProfileInstalled {
            return String(localized: "Removed earlier, downloads blocked")
        }
        return String(localized: "None on this Mac right now")
    }
}

/// What one open confirmation will remove.
struct AppleIntelligenceRemovalPlan: Identifiable {
    let id = UUID()
    let bytes: Int64?
    let sets: Int
    let otherAccounts: [AppleIntelligenceAccount]
    let reading: AppleIntelligenceReading?
}

/// Each set with Apple's figure for it, and the total: what the row's single
/// number is made of.
struct AppleIntelligenceBreakdown: View {
    let reading: AppleIntelligenceReading?

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text("Models on disk")
                .font(AppStyle.Typography.headline)
                .foregroundStyle(AppColors.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(AppleIntelligenceCatalog.sets.enumerated()), id: \.element.id) { index, set in
                    if index > 0 { InsetCardDivider() }
                    line(set.title, size(for: set), emphasized: false)
                }
                InsetCardDivider()
                line(String(localized: "Total"), total, emphasized: true)
            }
            .background(AppColors.fillSecondary, in: RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous))
        }
    }

    private func line(_ title: String, _ value: String, emphasized: Bool) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text(title)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: AppStyle.Spacing.small)
            Text(value)
                .font(emphasized ? AppStyle.Typography.callout.weight(.semibold) : AppStyle.Typography.callout)
                .foregroundStyle(emphasized ? AppColors.textPrimary : AppColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, 7)
    }

    private func size(for set: AppleIntelligenceModelSet) -> String {
        guard let item = reading?.sets.first(where: { $0.set.name == set.name }) else { return String(localized: "Checking...") }
        guard item.isPresent else { return String(localized: "None") }
        guard let bytes = item.latestBytes else { return String(localized: "Unknown") }
        return formatBytes(bytes)
    }

    private var total: String {
        guard let reading else { return String(localized: "Checking...") }
        guard reading.isAnythingPresent else { return String(localized: "None") }
        guard let bytes = reading.latestBytes else { return String(localized: "Unknown") }
        return formatBytes(bytes)
    }
}

/// Removing the models switches off features and installs a profile, so the
/// confirmation says both, and names the other accounts that share the models.
struct OverviewAppleIntelligenceConfirmation: View {
    let plan: AppleIntelligenceRemovalPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("Remove the Apple Intelligence models?")
                    .font(AppStyle.Typography.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text(sizeLine)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppleIntelligenceBreakdown(reading: plan.reading)

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("Until you download them again, these stop working:")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textPrimary)
                ForEach(AppleIntelligenceCatalog.consequences, id: \.self) { line in
                    Text("• " + line)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !plan.otherAccounts.isEmpty {
                Text(accountsLine)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("macOS will ask you to install a profile that stops the models downloading again. It stays in Device Management until you choose Download Again, which also brings the models back.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppStyle.Spacing.xSmall) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Remove Models", action: onConfirm)
                    .buttonStyle(.purge(.destructive))
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 480)
    }

    private var sizeLine: String {
        guard let bytes = plan.bytes else {
            return String(localized: "Apple's records don't say how much they take. Purge measures what the disk gives back.")
        }
        return String(localized: "Apple counts \(formatBytes(bytes)). macOS already treats part of that as available, so the disk gains less. Purge measures what it really gives back.")
    }

    private var accountsLine: String {
        let names = plan.otherAccounts.map { account -> String in
            switch account.usage {
            case .usesAppleIntelligence: return String(localized: "\(account.name) (uses Apple Intelligence)")
            case .off: return account.name
            case .unknown: return String(localized: "\(account.name) (can't tell)")
            }
        }
        return String(localized: "The models are shared by every account on this Mac: \(names.joined(separator: ", ")).")
    }
}
