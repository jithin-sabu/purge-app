import AppKit
import SwiftUI

struct AppCachesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Binding var items: [CacheItem]
    let isLoading: Bool
    let onScan: () -> Void

    @AppStorage("filter.appCaches") private var filterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("sort.appCaches") private var sortRaw: String = SortOption.sizeDesc.rawValue
    @AppStorage("onboarding.openRouterAPIKeyBannerDismissed") private var isOpenRouterAPIKeyBannerDismissed = false
    @AppStorage("hasCompletedFirstAIScan") private var hasCompletedFirstAIScan = false
    @AppStorage("hasSeenFirstScanBanner") private var hasSeenFirstScanBanner = false
    @AppStorage("hasSeenAIUpgradeBanner") private var hasSeenAIUpgradeBanner = false
    @State private var hasConfiguredOpenRouterAPIKey = false
    @State private var hasShownFirstScanLearningBannerThisSession = false
    @State private var hasDisplayedFirstScanCompletionThisSession = false
    @State private var showFirstScanCompletionBanner = false
    @State private var showFirstScanBanner = false
    @State private var hasScheduledFirstScanBannerAutoDismiss = false
    @State private var firstScanBannerAutoDismissTask: Task<Void, Never>?
    @State private var showAIUpgradeBanner = false
    @State private var hasScheduledAIUpgradeBannerAutoDismiss = false
    @State private var aiUpgradeBannerAutoDismissTask: Task<Void, Never>?
    /// Last completed scan snapshot; used for chip counts during an in-flight rescan so counts don’t collapse to zero.
    @State private var displayedItems: [CacheItem] = []

    private var currentSafetyFilter: SafetyFilter {
        SafetyFilter(rawValue: filterRaw) ?? .all
    }

    private var safetyFilterBinding: Binding<SafetyFilter> {
        Binding(
            get: { SafetyFilter(rawValue: filterRaw) ?? .all },
            set: { filterRaw = $0.rawValue }
        )
    }

    private var sortOptionBinding: Binding<SortOption> {
        Binding(
            get: { SortOption(rawValue: sortRaw) ?? .sizeDesc },
            set: { sortRaw = $0.rawValue }
        )
    }

    private var visibleIndices: [Int] {
        items.indices.filter { currentSafetyFilter.matches(items[$0].safetyInfo) }
    }

    /// Chip aggregates during scan use the last finished scan so the chip row doesn’t resize from 0 mid-scan.
    private var itemsForChipCounts: [CacheItem] {
        isLoading ? displayedItems : items
    }

    /// Bulk selection / Select All includes Do Not Delete and Not Sure (when not awaiting AI).
    private var eligibleSelectIndices: [Int] {
        visibleIndices.filter {
            let info = items[$0].safetyInfo
            switch info.level {
            case .safe, .medium, .danger:
                return true
            case .unknown:
                return !ExplanationResolver.isAwaitingAI(info)
            }
        }
    }

    private func sortedVisibleIndices() -> [Int] {
        let base = visibleIndices
        switch SortOption(rawValue: sortRaw) ?? .sizeDesc {
        case .sizeDesc:
            return base.sorted { items[$0].sizeBytes > items[$1].sizeBytes }
        case .sizeAsc:
            return base.sorted { items[$0].sizeBytes < items[$1].sizeBytes }
        case .dateNewest:
            return base.sorted { items[$0].lastModified > items[$1].lastModified }
        case .dateOldest:
            return base.sorted { items[$0].lastModified < items[$1].lastModified }
        case .nameAZ:
            return base.sorted { items[$0].appName.localizedCaseInsensitiveCompare(items[$1].appName) == .orderedAscending }
        }
    }

    private var selectAllState: SelectAllTriState {
        let ix = eligibleSelectIndices
        guard !ix.isEmpty else { return .none }
        let selected = ix.filter { items[$0].isSelected }
        if selected.count == ix.count { return .all }
        if selected.isEmpty { return .none }
        return .mixed
    }

    private var chipCounts: [SafetyFilter: Int] {
        let source = itemsForChipCounts
        var d: [SafetyFilter: Int] = [:]
        for filter in SafetyFilter.allCases {
            switch filter {
            case .all:
                d[filter] = source.count
            case .safe:
                d[filter] = source.filter { $0.safetyInfo.level == .safe }.count
            case .medium:
                d[filter] = source.filter { $0.safetyInfo.level == .medium }.count
            case .danger:
                d[filter] = source.filter { $0.safetyInfo.level == .danger }.count
            case .unknown:
                d[filter] = source.filter { $0.safetyInfo.level == .unknown }.count
            }
        }
        return d
    }

    private var pendingAIResolutionCount: Int {
        items.filter { ExplanationResolver.isAwaitingAI($0.safetyInfo) }.count
    }

    private var identificationProgress: Int {
        let total = items.count
        guard total > 0 else { return 0 }
        let identified = items.filter {
            !ExplanationResolver.isAwaitingAI($0.safetyInfo)
        }.count
        return Int((Double(identified) / Double(total)) * 100)
    }

    private var hasAPIKey: Bool {
        !(KeychainStore.read(key: "openrouter-api-key") ?? "").isEmpty
    }

    /// Percent of unknown rows the post-key AI sweep has resolved so far (0–100).
    private var aiUpgradeProgress: Int {
        let total = store.unknownReidentifyTotal
        guard total > 0 else { return 0 }
        let done = min(store.unknownReidentifyResolved, total)
        return Int((Double(done) / Double(total)) * 100)
    }

    private var selectedInScopeCount: Int {
        eligibleSelectIndices.filter { items[$0].isSelected }.count
    }

    private var totalSize: Int64 {
        items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var visibleTotalSize: Int64 {
        visibleIndices.reduce(Int64(0)) { sum, index in sum + items[index].sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showFirstScanBanner {
                firstScanLearningBanner
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            } else if showFirstScanCompletionBanner {
                firstScanCompletionBanner
            }

            if showAIUpgradeBanner {
                aiUpgradeBanner
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }

            if shouldShowOpenRouterAPIKeyBanner {
                openRouterAPIKeyBanner
            }

            FilterSortToolbar(
                safetyFilter: safetyFilterBinding,
                sortOption: sortOptionBinding,
                chipCounts: chipCounts,
                selectedInScopeCount: selectedInScopeCount,
                isDeleting: store.isDeleting,
                onCleanSelected: {
                    Task {
                        await store.presentDeletionSheetResolvingGit(candidates: store.selectedGeneralDeletionCandidates)
                    }
                },
                pendingAIResolutionCount: pendingAIResolutionCount,
                useStackedLayout: true,
                showsControlsRow: false
            )
            .padding(.horizontal)
            .padding(.top, filterToolbarTopPadding)
            .opacity(isLoading ? 0.4 : 1.0)
            .disabled(isLoading)

            HStack {
                TriStateCheckbox(title: "Select All", state: selectAllState) {
                    toggleSelectAll()
                }
                .fixedSize()
                .disabled(isLoading || eligibleSelectIndices.isEmpty)
                Spacer()
                Picker("Sort", selection: sortOptionBinding) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .opacity(isLoading ? 0.4 : 1.0)
            .disabled(isLoading)

            ZStack {
                if isLoading && items.isEmpty {
                    ScanListSkeletonPlaceholder()
                } else if items.isEmpty {
                    emptyState
                } else if visibleIndices.isEmpty {
                    emptyFilterState
                } else {
                    List {
                        ForEach(sortedVisibleIndices(), id: \.self) { index in
                            let item = items[index]
                            let itemID = item.id
                            ScanResultRow(
                                isSelected: $items[index].isSelected,
                                primaryLabel: item.appName,
                                formattedSize: item.formattedSize,
                                dateModifiedLine: DateFormatter.localizedString(
                                    from: item.lastModified,
                                    dateStyle: .medium,
                                    timeStyle: .short
                                ),
                                safetyInfo: item.safetyInfo,
                                icon: appIcon(for: item),
                                onRequestUnknownDelete: item.safetyInfo.level == .unknown && !ExplanationResolver.isAwaitingAI(item.safetyInfo)
                                    ? { store.requestUnknownDeletion(PurgeStore.DeletionCandidate.forCache(item)) }
                                    : nil,
                                detailCaption: nil,
                                reinstallSafety: reinstallDisplay(for: item),
                                showUncommittedRepoChanges: item.gitStatus == .dirty,
                                onRecategorize: { store.recategorizeCacheItem(id: itemID) },
                                onMarkSafe: { store.markCacheItem(id: itemID, as: .safe) },
                                onMarkMedium: { store.markCacheItem(id: itemID, as: .medium) },
                                onMarkDanger: { store.markCacheItem(id: itemID, as: .danger) },
                                onResetToAutomatic: { store.resetCacheItemToAutomatic(id: itemID) },
                                isUserOverride: store.userOverridePaths.contains(item.path.standardizedFileURL.path)
                            )
                            .disabled(isLoading)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if isLoading {
                    Text("Scanning…")
                } else if currentSafetyFilter == .all {
                    Text("\(items.count) items")
                } else {
                    Text("\(visibleIndices.count) of \(items.count) items")
                }
                Spacer()
                if isLoading {
                    Text("")
                } else {
                    Text("Total: \(formatBytes(currentSafetyFilter == .all ? totalSize : visibleTotalSize))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("App Caches")
        .onAppear {
            refreshOpenRouterAPIKeyBannerState()
            if !isLoading {
                displayedItems = items
            }
            syncFirstScanBannerVisibilityForAppear()
            syncAIUpgradeBannerVisibilityForAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyAdded)) { _ in
            guard !hasSeenAIUpgradeBanner else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                showAIUpgradeBanner = true
            }
        }
        .onChange(of: aiUpgradeProgress) { newProgress in
            scheduleAIUpgradeBannerAutoDismissIfComplete(progress: newProgress)
        }
        .onChange(of: isLoading) { scanning in
            if !scanning {
                displayedItems = items
            }
        }
        .onChange(of: items) { newItems in
            if !isLoading {
                displayedItems = newItems
            }
        }
        .onChange(of: pendingAIResolutionCount) { newCount in
            if newCount > 0 && !hasSeenFirstScanBanner && !hasCompletedFirstAIScan {
                showFirstScanBanner = true
                hasShownFirstScanLearningBannerThisSession = true
            }
        }
        .onChange(of: identificationProgress) { newProgress in
            guard newProgress == 100,
                  showFirstScanBanner,
                  !hasSeenFirstScanBanner,
                  items.count > 0,
                  !hasScheduledFirstScanBannerAutoDismiss
            else { return }
            hasScheduledFirstScanBannerAutoDismiss = true
            firstScanBannerAutoDismissTask?.cancel()
            firstScanBannerAutoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showFirstScanBanner = false
                    }
                }
            }
        }
        .onChange(of: store.firstAIScanCompletionBannerID) { bannerID in
            guard bannerID != nil,
                  hasShownFirstScanLearningBannerThisSession,
                  !hasDisplayedFirstScanCompletionThisSession else { return }
            hasDisplayedFirstScanCompletionThisSession = true
            showTemporaryFirstScanCompletionBanner()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onScan) {
                    Label("Scan", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private var shouldShowOpenRouterAPIKeyBanner: Bool {
        !isOpenRouterAPIKeyBannerDismissed && !hasConfiguredOpenRouterAPIKey
    }

    private var filterToolbarTopPadding: CGFloat { 8 }

    private var firstScanLearningBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(hasAPIKey ? "Learning your Mac for the first time" : "Scanning your Mac for the first time")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Got it") {
                        firstScanBannerAutoDismissTask?.cancel()
                        firstScanBannerAutoDismissTask = nil
                        withAnimation(.easeInOut(duration: 0.35)) {
                            showFirstScanBanner = false
                        }
                        hasSeenFirstScanBanner = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                }

                Text(
                    hasAPIKey
                        ? "Purge is identifying unfamiliar folders using AI. Future scans will be instant · \(identificationProgress)% done"
                        : "Purge is mapping your cache folders. Results are saved so future scans are faster · \(identificationProgress)% done"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: identificationProgress)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func syncFirstScanBannerVisibilityForAppear() {
        if !hasSeenFirstScanBanner && !hasCompletedFirstAIScan && pendingAIResolutionCount > 0 {
            showFirstScanBanner = true
            hasShownFirstScanLearningBannerThisSession = true
        }
    }

    /// Re-show the AI upgrade banner when the user navigates back to App Caches
    /// while the post-key sweep is still in flight. Lets the banner "follow" the
    /// user across tabs without requiring a fresh notification.
    private func syncAIUpgradeBannerVisibilityForAppear() {
        guard !hasSeenAIUpgradeBanner else { return }
        guard store.isReidentifyingUnknownItems || store.unknownReidentifyTotal > 0 else { return }
        guard !showAIUpgradeBanner else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            showAIUpgradeBanner = true
        }
    }

    private func scheduleAIUpgradeBannerAutoDismissIfComplete(progress: Int) {
        guard progress >= 100,
              showAIUpgradeBanner,
              !hasScheduledAIUpgradeBannerAutoDismiss
        else { return }
        hasScheduledAIUpgradeBannerAutoDismiss = true
        aiUpgradeBannerAutoDismissTask?.cancel()
        aiUpgradeBannerAutoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.35)) {
                    showAIUpgradeBanner = false
                }
                hasSeenAIUpgradeBanner = true
            }
        }
    }

    private var aiUpgradeBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text("AI is now identifying your unknown folders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Got it") {
                        aiUpgradeBannerAutoDismissTask?.cancel()
                        aiUpgradeBannerAutoDismissTask = nil
                        withAnimation(.easeInOut(duration: 0.35)) {
                            showAIUpgradeBanner = false
                        }
                        hasSeenAIUpgradeBanner = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                }

                Text("Purge is categorising folders it could not identify before. Results are saved permanently · \(aiUpgradeProgress)% done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: aiUpgradeProgress)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var firstScanCompletionBanner: some View {
        Text("✓ Done. Purge has learned your Mac's folders and future scans will be instant.")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .transition(.opacity)
    }

    private func showTemporaryFirstScanCompletionBanner() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showFirstScanCompletionBanner = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    showFirstScanCompletionBanner = false
                }
            }
        }
    }

    private var openRouterAPIKeyBanner: some View {
        HStack(spacing: 12) {
            Text("Add an OpenRouter API key in Settings to identify unknown cache folders automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Add Key") {
                isOpenRouterAPIKeyBannerDismissed = true
                store.selectedTab = .settings
            }
            .controlSize(.small)

            Spacer()

            Button {
                isOpenRouterAPIKeyBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss OpenRouter API key prompt")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func refreshOpenRouterAPIKeyBannerState() {
        if KeychainStore.read(key: "openrouter-api-key") != nil {
            hasConfiguredOpenRouterAPIKey = true
            return
        }

        let environmentKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasConfiguredOpenRouterAPIKey = environmentKey?.isEmpty == false
    }

    private func reinstallDisplay(for item: CacheItem) -> ReinstallSafetyStatus? {
        guard item.reinstallSafety != .notApplicable else { return nil }
        return item.reinstallSafety
    }

    private var emptyFilterState: some View {
        VStack(spacing: 4) {
            Text("Nothing here.")
                .font(.headline)
            Text("No items match this filter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleSelectAll() {
        let ix = eligibleSelectIndices
        guard !ix.isEmpty else { return }
        let allOn = ix.allSatisfy { items[$0].isSelected }
        let newVal = !allOn
        for i in ix {
            items[i].isSelected = newVal
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Caches Found")
                .font(.title3)
            Text("Run a scan to inspect recoverable application caches.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appIcon(for item: CacheItem) -> NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSWorkspace.shared.icon(forFile: item.path.path)
    }
}
