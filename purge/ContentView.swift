//
//  ContentView.swift
//  purge
//
//  Created by Jithin Sabu on 05/05/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    var isLifecycleActive: Bool = true

    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarding.pendingCelebration") private var pendingOnboardingCelebration = false
    // Same defaults as the tabs, so the subtitle counts what the list shows.
    @AppStorage("filter.appCaches") private var appCachesFilterRaw: String = SafetyFilter.safe.rawValue
    @AppStorage("filter.devTools") private var devToolsFilterRaw: String = SafetyFilter.safe.rawValue
    @AppStorage(LargeFileFilterDefaults.categoryKey) private var largeFilesCategoryFilterRaw = LargeFileCategoryFilter.all

    /// Large Files search text. Held here rather than inside `LargeFilesView` so the
    /// page header subtitle can be filtered by it too, and deliberately `@State`
    /// rather than `@AppStorage` like the filters beside it: a query that survived
    /// relaunch would silently hide most of the list on next open, with the only clue
    /// a few characters in a field the user has long forgotten typing.
    @State private var largeFilesSearchQuery = ""

    /// Mirror of `store.largeFileDuplicates.index`, needed because the page header
    /// subtitle counts the same rows the Duplicates filter shows. The index lives
    /// in its own observable that this view does not observe (deliberately — see
    /// `LargeFileDuplicateIndex`), and nothing else re-renders `ContentView` when
    /// a duplicate pass lands, so without this the subtitle kept quoting the
    /// pre-grouping count.
    @State private var largeFilesDuplicateIndex: DuplicateIndex = .empty
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    private let isRunningPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    /// Scheduled cleaning used to be kept out of the test host by accident: the host
    /// never has Full Disk Access, and cleaning required it. Cleaning no longer does,
    /// so the host is excluded on purpose.
    private let isRunningAsTestHost = TestHost.isActive()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            sidebarDivider
            detailColumn
        }
        .task {
            await runStartupMaintenance()
        }
        .onReceive(store.largeFileDuplicates.indexPublisher) { index in
            largeFilesDuplicateIndex = index
        }
        .onChange(of: scenePhase) { phase in
            guard isLifecycleActive, phase == .active, !isRunningPreview, !isRunningAsTestHost else { return }
            Task {
                await ScheduledCleaningRegistrar.shared.runGracefulActivationSweepIfPastDue()
            }
        }
        .onChange(of: isLifecycleActive) { isActive in
            guard isActive else { return }
            Task { await runStartupMaintenance() }
        }
        // Access granted while Purge is open: rescan with it, and the Overview fills in.
        .onChange(of: store.hasFullDiskAccess) { granted in
            guard granted, isLifecycleActive, !isRunningPreview, !isRunningAsTestHost else { return }
            store.scanAfterAccessGranted()
        }
        .sheet(isPresented: $store.isLookDeeperPresented) {
            LookDeeperSheet()
        }
        .sheet(isPresented: $store.showDeletionSheet) {
            DeletionConfirmSheet(
                candidates: store.deletionCandidatesForSheet,
                onCancel: { store.dismissDeletionSheet() },
                onConfirm: {
                    store.userConfirmedDeletionFromPrimarySheet()
                }
            )
        }
        .sheet(item: $store.pendingUnknownDeletion) { payload in
            UnknownDeleteConfirmSheet(
                candidates: payload.candidates,
                onCancel: { store.dismissUnknownDeletionRequest() },
                onConfirm: {
                    Task { await store.userConfirmedUnknownDeletionFlow() }
                }
            )
        }
        .sheet(isPresented: $store.showLargeFileDeletionSheet) {
            LargeFileDeletionConfirmSheet(
                files: store.selectedLargeFiles,
                fullyConsumedDuplicateGroups: store.duplicateGroupsFullyConsumedBySelection,
                onCancel: { store.dismissLargeFileDeletionSheet() },
                onConfirm: { Task { await store.confirmLargeFileDeletion() } }
            )
        }
        .sheet(item: $store.pendingDuplicateCleanup) { request in
            DuplicateCleanupSheet(
                request: request,
                onCancel: { store.dismissDuplicateCleanup() },
                onConfirm: { keepers in Task { await store.confirmDuplicateCleanup(keeperByGroupID: keepers) } }
            )
        }
        .sheet(item: $store.uninstallPlan) { plan in
            UninstallReviewSheet(
                plan: plan,
                onCancel: { store.dismissUninstallPlan() },
                onConfirm: { edited in Task { await store.confirmUninstallPlan(edited) } }
            )
        }
        .sheet(item: $store.orphanCleanupPlan) { plan in
            OrphanReviewSheet(
                plan: plan,
                onCancel: { store.cancelOrphanCleanup() },
                onConfirm: { edited in Task { await store.confirmOrphanCleanup(edited) } }
            )
        }
        .sheet(item: $store.removedAppLeftoverPlan) { plan in
            RemovedAppLeftoverSheet(
                plan: plan,
                onCancel: { store.cancelRemovedAppLeftovers() },
                onConfirm: { edited in Task { await store.confirmRemovedAppLeftovers(edited) } }
            )
        }
        .disabled(store.isManualCleaningInProgress)
        .overlay {
            if isLifecycleActive, let session = store.interactiveSafeCleanupSession {
                SafeCleanupCelebrationOverlay(session: session) {
                    completeInteractiveSafeCleanupCelebration()
                }
                .transition(reduceMotion ? .opacity : .safeCleanupCelebrationBlur)
                .zIndex(90)
            }

            if isLifecycleActive, let movedBytes = store.onboardingCelebrationMovedToTrashBytes {
                OnboardingCelebrationView(bytesMovedToTrash: movedBytes) {
                    completeOnboardingCelebration()
                }
                .transition(.opacity)
                .zIndex(100)
            }

            if isLifecycleActive, let session = store.manualDeletionSession {
                SafeCleanupCelebrationOverlay(session: session) {
                    completeDeletionSummary()
                }
                .transition(reduceMotion ? .opacity : .safeCleanupCelebrationBlur)
                .zIndex(90)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.35),
            value: store.interactiveSafeCleanupSession != nil
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.35),
            value: store.manualDeletionSession != nil
        )
        .alert(
            "Missing reinstall instructions",
            isPresented: $store.showMissingLockfileFriction
        ) {
            Button("Cancel", role: .cancel) { store.cancelDeletionFrictionFlow() }
            Button("Delete anyway", role: .destructive) { store.acknowledgeMissingLockfileRisk() }
        } message: {
            Text(
                """
                We could not find the file that tells us how to reinstall this folder. Deleting is probably fine, but \
                when you reinstall later it might download slightly different versions than before.
                """
            )
        }
        .alert(
            "You have unsaved code changes nearby",
            isPresented: $store.showUncommittedGitFriction
        ) {
            Button("Pause", role: .cancel) { store.cancelDeletionFrictionFlow() }
            Button("Clean anyway", role: .destructive) { store.acknowledgeUncommittedGitRisk() }
        } message: {
            Text(
                """
                One of your projects has changes that have not been saved to git yet. Make sure your work is backed \
                up before cleaning. Purge cannot undo deletions.
                """
            )
        }
        .alert(
            "Permanently delete these items?",
            isPresented: $store.showHighRiskDeletionSecondConfirm
        ) {
            Button("Cancel", role: .cancel) { store.cancelHighRiskDeletionSecondStep() }
            Button("Delete permanently", role: .destructive) { store.confirmHighRiskDeletionSecondStep() }
        } message: {
            Text(
                """
                This includes folders marked Not Sure. They will be moved to Trash. \
                Only continue if you understand the risk.
                """
            )
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minHeight)
        .fixedAppWindowWidth()
        .tint(AppColors.textPrimary)
        .modifier(DiskSummaryRefreshModifier())
    }

    /// Hairline between the flush sidebar and the detail column, matching the
    /// separator NavigationSplitView used to draw.
    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppColors.borderSubtle)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .id(appearanceModeRaw)
    }

    private var detailColumn: some View {
        tabContent
            .frame(minWidth: 600, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailColumnCompactTop()
    }

    private func scanIfNeeded() async {
        guard isLifecycleActive, !isRunningPreview else { return }
        // A grant that came with macOS's "Quit & Reopen" is only visible here, on
        // the first launch after it. Land on the Overview so the unlocked figures
        // fill in where the user can see them.
        if store.consumeFullDiskAccessGrant() {
            store.selectedTab = .overview
        }
        // One step at a time: App Caches and Dev Tools, then Large Files, apps and
        // leftovers. A scan the menu bar already started is waited on, not restarted,
        // and steps that already have results in this session are skipped.
        store.startLaunchScans()
    }

    /// Runs any past-due scheduled clean before the first scan so the UI reflects
    /// the post-clean state. `.onChange(of: scenePhase)` never fires for the initial
    /// `.active` value, so without this a cold launch would skip the activation
    /// sweep entirely and an overdue clean would sit unexecuted.
    private func runStartupMaintenance() async {
        guard isLifecycleActive, !isRunningPreview, !isRunningAsTestHost else { return }
        await ScheduledCleaningRegistrar.shared.runGracefulActivationSweepIfPastDue()
        await scanIfNeeded()
    }

    private func completeInteractiveSafeCleanupCelebration() {
        if reduceMotion {
            store.dismissInteractiveSafeCleanupCelebration()
            diskStore.refresh()
            return
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            store.dismissInteractiveSafeCleanupCelebration()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeInOut(duration: 0.6)) {
                diskStore.refresh()
            }
        }
    }

    private func completeDeletionSummary() {
        if reduceMotion {
            store.dismissManualDeletionSession()
            store.lastDeletionReport = nil
            diskStore.refresh()
            return
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            store.dismissManualDeletionSession()
            store.lastDeletionReport = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeInOut(duration: 0.6)) {
                diskStore.refresh()
            }
        }
    }

    private func completeOnboardingCelebration() {
        pendingOnboardingCelebration = false
        store.onboardingCelebrationMovedToTrashBytes = nil
        diskStore.refresh()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                AppBrandMark()
                    .padding(.top, SidebarLayout.topContentInset)
                    .padding(.bottom, AppStyle.Spacing.large)

                VStack(alignment: .leading, spacing: 2) {
                    navRow(.overview)
                    sidebarSectionLabel("Clean")
                    ForEach(PurgeStore.Tab.cleanTabs) { navRow($0) }
                    sidebarSectionLabel("Review")
                    ForEach(PurgeStore.Tab.reviewTabs) { navRow($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppStyle.Spacing.small)

            Spacer(minLength: AppStyle.Spacing.medium)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(PurgeStore.Tab.utilityTabs) { navRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.bottom, AppStyle.Spacing.xSmall)

            SidebarSummaryView()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .frame(width: SidebarLayout.width)
        .background(AppColors.bgCard)
        .sidebarCompactTop()
    }

    private func navRow(_ tab: PurgeStore.Tab) -> some View {
        AppNavRow(
            title: tab.rawValue,
            systemImage: tab.icon,
            isSelected: store.selectedTab == tab,
            accessory: navAccessory(for: tab),
            action: { store.selectedTab = tab }
        )
    }

    /// Groups the scan tabs by what Purge may do with what they find.
    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SidebarLayout.navRowInnerPadding)
            .padding(.top, AppStyle.Spacing.small)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// The same figure the Overview shows for the tab, or a spinner while its scan runs,
    /// so the scan queue's progress is visible from any tab.
    private func navAccessory(for tab: PurgeStore.Tab) -> AppNavRow.Accessory {
        let categories: [OverviewCategory]
        switch tab {
        case .appCaches: categories = [.appCaches]
        case .devTools: categories = [.devTools]
        case .largeFiles: categories = [.largeFiles]
        case .uninstaller: categories = [.apps, .leftovers]
        case .overview, .settings, .about: return .none
        }
        let phases = categories.map(store.overviewPhase(for:))
        // The Uninstaller covers two scans. Once one is redone and the other still
        // waits, the tab is mid-rescan, not finished with half a figure.
        let isMidRescan = phases.contains(.waiting) && phases.contains { $0 != .waiting }
        if phases.contains(.scanning) || isMidRescan {
            return .progress
        }
        let breakdown = store.overviewBreakdown(
            totalBytes: diskStore.totalDiskBytes,
            freeBytes: diskStore.freeDiskBytes
        )
        let bytes = categories.reduce(Int64(0)) { $0 + breakdown.bytes(for: $1) }
        guard bytes > 0 else { return .none }
        let isDimmed = categories.contains(where: store.isShowingRecordedFigure(for:))
        return .value(formatStorageBytes(bytes), isDimmed: isDimmed)
    }

    /// Shared overlaid header so `AnimatedPageTitle` stays mounted across tab switches.
    /// About reserves matching space in its `safeAreaBar` (invisible) so cards still blur.
    private var tabContent: some View {
        ZStack(alignment: .top) {
            ZStack {
                AppColors.bgBase
                    .ignoresSafeArea()

                tabBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            selectedPageHeader
        }
        .background(AppColors.bgBase)
    }

    // Deliberately a plain `switch`, i.e. the incoming tab is built fresh. Keeping
    // visited tabs mounted in a ZStack and toggling opacity was tried and measured: it
    // helped the first few switches but was a net regression (p95 33ms → 50ms with all
    // tabs mounted, 41ms with just the two scan tabs), because a mounted tab still
    // re-evaluates its body on every store publish. Don't re-propose it without new
    // measurements.
    @ViewBuilder
    private var tabBody: some View {
        switch store.selectedTab {
        case .overview:
            overviewTabBody
        case .about:
            aboutTabBody
        // App Caches and Dev Tools work without Full Disk Access (limited scans). Large Files
        // and the uninstaller need it and show `LockedFeatureView` until it is granted.
        case .appCaches:
            appCachesTabBody
        case .devTools:
            devToolsTabBody
        case .largeFiles:
            largeFilesTabBody
        case .uninstaller:
            uninstallerTabBody
        case .settings:
            settingsTabBody
        }
    }

    @ViewBuilder
    private var uninstallerTabBody: some View {
        Group {
            if store.hasFullDiskAccess {
                UninstallView()
            } else {
                LockedFeatureView(feature: .uninstaller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .underDetailPageHeader(includesSubtitle: store.hasFullDiskAccess)
    }

    @ViewBuilder
    private var settingsTabBody: some View {
        Group {
            if #available(macOS 26.0, *) {
                settingsScrollView
                    .detailPageScrollEdge(title: "Settings")
            } else {
                settingsScrollView
                    .underDetailPageHeader(includesSubtitle: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsScrollView: some View {
        ScrollView {
            SettingsView(showsPageHeader: false, usesExternalScrollContainer: true)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
    }

    @ViewBuilder
    private var appCachesTabBody: some View {
        Group {
            if #available(macOS 26.0, *) {
                AppCachesView(
                    items: $store.cacheItems,
                    isLoading: store.isScanningGeneral || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { store.requestScan(.cachesAndDevTools) },
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                AppCachesView(
                    items: $store.cacheItems,
                    isLoading: store.isScanningGeneral || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { store.requestScan(.cachesAndDevTools) },
                    showsPageHeader: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .underDetailPageHeader(includesSubtitle: true)
    }

    @ViewBuilder
    private var devToolsTabBody: some View {
        Group {
            if #available(macOS 26.0, *) {
                DevToolsView(
                    isLoading: store.isScanningDeveloper || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { store.requestScan(.cachesAndDevTools) },
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                DevToolsView(
                    isLoading: store.isScanningDeveloper || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { store.requestScan(.cachesAndDevTools) },
                    showsPageHeader: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .underDetailPageHeader(includesSubtitle: true)
    }

    @ViewBuilder
    private var largeFilesTabBody: some View {
        Group {
            if !store.hasFullDiskAccess {
                LockedFeatureView(feature: .largeFiles)
            } else if #available(macOS 26.0, *) {
                LargeFilesView(
                    isLoading: store.isScanningLargeFiles,
                    onScan: { store.requestScan(.largeFiles) },
                    searchQuery: $largeFilesSearchQuery,
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                LargeFilesView(
                    isLoading: store.isScanningLargeFiles,
                    onScan: { store.requestScan(.largeFiles) },
                    searchQuery: $largeFilesSearchQuery,
                    showsPageHeader: false
                )
            }
        }
        .underDetailPageHeader(includesSubtitle: store.hasFullDiskAccess)
        // Keyed on access so granting it while this tab is open starts the scan.
        // Goes through the queue, so it runs next rather than beside another scan.
        .task(id: store.hasFullDiskAccess) {
            guard !isRunningPreview else { return }
            store.requestScanIfNeeded(.largeFiles)
        }
    }

    @ViewBuilder
    private var overviewTabBody: some View {
        Group {
            if #available(macOS 26.0, *) {
                overviewScrollView
                    .detailPageScrollEdge(title: "Overview", includesSubtitle: true)
            } else {
                overviewScrollView
                    .underDetailPageHeader(includesSubtitle: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overviewScrollView: some View {
        ScrollView {
            OverviewView()
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
    }

    @ViewBuilder
    private var aboutTabBody: some View {
        Group {
            if #available(macOS 26.0, *) {
                aboutScrollView
                    .detailPageScrollEdge(title: "About")
            } else {
                aboutScrollView
                    .underDetailPageHeader(includesSubtitle: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var aboutScrollView: some View {
        ScrollView {
            AboutView(showsPageHeader: false, usesExternalScrollContainer: true)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
    }

    private var selectedPageHeader: some View {
        // Periodic so "Scanned 5m ago" on the Overview moves without a store change.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            pageHeader(now: context.date)
        }
    }

    private func pageHeader(now: Date) -> some View {
        AppSectionPageHeader(title: store.selectedTab.rawValue, subtitle: selectedPageSubtitle(now: now)) {
            if store.selectedTab == .overview {
                HStack(spacing: AppStyle.Spacing.xSmall) {
                    if !store.hasFullDiskAccess {
                        LookDeeperHeaderButton()
                    }
                    OverviewScanButton()
                }
            } else if store.selectedTab == .appCaches || store.selectedTab == .devTools {
                HStack(spacing: AppStyle.Spacing.xSmall) {
                    if !store.hasFullDiskAccess {
                        LookDeeperHeaderButton()
                    }
                    AppScanCleanActions(
                        onScan: { store.requestScan(.cachesAndDevTools) },
                        scanPhase: store.scanPhase,
                        isQueued: store.isScanQueued(.cachesAndDevTools)
                    )
                }
            } else if store.selectedTab == .largeFiles, store.hasFullDiskAccess {
                LargeFilesHeaderActions()
            } else if store.selectedTab == .uninstaller, store.hasFullDiskAccess {
                UninstallHeaderActions()
            }
        }
    }

    private func selectedPageSubtitle(now: Date) -> String? {
        switch store.selectedTab {
        case .overview:
            return overviewPageSubtitle(now: now)
        case .appCaches:
            return pageSubtitle(count: appCachesSubtitleItemCount, bytes: appCachesSubtitleTotalSize)
        case .devTools:
            return pageSubtitle(count: devToolsSubtitleItemCount, bytes: devToolsSubtitleTotalSize)
        case .largeFiles:
            return store.hasFullDiskAccess ? largeFilesPageSubtitle : nil
        case .uninstaller:
            return store.hasFullDiskAccess ? uninstallerPageSubtitle : nil
        case .settings:
            return nil
        case .about:
            return nil
        }
    }

    /// What the scan queue is doing, or when the Overview's figures were last scanned.
    private func overviewPageSubtitle(now: Date) -> String? {
        if let active = store.scanQueue.active {
            let waiting = store.scanQueue.pending.count
            let name = OverviewScanButton.name(for: active)
            return waiting > 0 ? "Scanning \(name), then \(waiting) more…" : "Scanning \(name)…"
        }
        if store.isScanningAll {
            return "Scanning \(OverviewScanButton.name(for: .cachesAndDevTools))…"
        }
        guard let latest = store.scanRecords.values.map(\.completedAt).max() else { return nil }
        return "Scanned \(compactAgoText(from: latest, to: now))"
    }

    private func pageSubtitle(count: Int, bytes: Int64) -> String {
        let itemLabel = count == 1 ? "item" : "items"
        return "\(count) \(itemLabel) · \(formatBytes(bytes)) recoverable"
    }

    /// Mirrors the filtering `LargeFilesView` applies to its list, so the subtitle
    /// counts the rows the user can actually see. The category predicate is shared
    /// through `LargeFileCategoryFilter` rather than restated, because restating it
    /// is how the header once ended up advertising a different list than the one on
    /// screen.
    private var largeFilesVisibleForSubtitle: [LargeFile] {
        let files = store.largeFiles
        return LargeFileCategoryFilter.visibleIndices(
            in: files,
            rawValue: largeFilesCategoryFilterRaw,
            query: largeFilesSearchQuery,
            duplicates: largeFilesDuplicateIndex
        ).map { files[$0] }
    }

    private var largeFilesPageSubtitle: String {
        let files = largeFilesVisibleForSubtitle
        let bytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let fileLabel = files.count == 1 ? "file" : "files"
        return "\(files.count) \(fileLabel) · \(formatBytes(bytes)) to review"
    }

    /// Follows the active segment, with one shared shape so the two read the same:
    /// "N units · total size" at rest, and "N units · M selected · selected size"
    /// once anything is ticked.
    private var uninstallerPageSubtitle: String? {
        if store.uninstallSection == .leftovers {
            let items = store.orphanLeftovers
            guard !items.isEmpty else { return nil }
            return uninstallSubtitle(
                count: items.count,
                unit: ("item", "items"),
                totalBytes: items.reduce(Int64(0)) { $0 + $1.sizeBytes },
                selectedCount: store.selectedOrphanCount,
                selectedBytes: store.selectedOrphanBytes,
                measuring: false
            )
        }

        guard !store.installedApps.isEmpty else { return nil }
        return uninstallSubtitle(
            count: store.installedApps.count,
            unit: ("app", "apps"),
            totalBytes: store.installedApps.reduce(Int64(0)) { $0 + store.removableBytes(for: $1) },
            selectedCount: store.selectedAppIDs.count,
            selectedBytes: store.selectedAppsRemovableBytes,
            // App totals fill in on a background pass; say so rather than show a
            // size that is still climbing.
            measuring: !store.hasMeasuredAllRemovableTotals
        )
    }

    private func uninstallSubtitle(
        count: Int,
        unit: (singular: String, plural: String),
        totalBytes: Int64,
        selectedCount: Int,
        selectedBytes: Int64,
        measuring: Bool
    ) -> String {
        let base = "\(count) \(count == 1 ? unit.singular : unit.plural)"
        if selectedCount > 0 {
            return "\(base) · \(selectedCount) selected · \(formatBytes(selectedBytes))"
        }
        if measuring {
            return "\(base) · measuring space…"
        }
        return "\(base) · \(formatBytes(totalBytes))"
    }

    private var appCachesSafetyFilter: SafetyFilter {
        store.safetyFilter(for: .appCaches, saved: SafetyFilter(rawValue: appCachesFilterRaw) ?? .all)
    }

    private var appCachesVisibleItems: [CacheItem] {
        store.cacheItems.filter {
            appCachesSafetyFilter.matches($0.safetyInfo) && !store.isVisuallyRemovedBySafeCleanup($0)
        }
    }

    // With no filter the subtitle quotes the shared totals the sidebar and Overview use.
    private var appCachesSubtitleItemCount: Int {
        appCachesSafetyFilter == .all ? store.appCachesTotals.count : appCachesVisibleItems.count
    }

    private var appCachesSubtitleTotalSize: Int64 {
        appCachesSafetyFilter == .all
            ? store.appCachesTotals.bytes
            : appCachesVisibleItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var devToolsSafetyFilter: SafetyFilter {
        store.safetyFilter(for: .devTools, saved: SafetyFilter(rawValue: devToolsFilterRaw) ?? .all)
    }

    private var devToolsSubtitleItemCount: Int {
        devToolsSafetyFilter == .all ? store.devToolsTotals.count : devToolsVisibleItemCount
    }

    private var devToolsSubtitleTotalSize: Int64 {
        devToolsSafetyFilter == .all ? store.devToolsTotals.bytes : devToolsVisibleByteSize
    }

    private var devToolsVisibleItemCount: Int {
        let tools = store.devTools.filter(devToolVisible).count
        let sims = store.simulatorDevices.filter { devToolsSafetyFilter.matches($0.safetyInfo) }.count
        let artifacts = store.projectGroups.reduce(0) { sum, group in
            sum + group.artifacts.filter(projectArtifactVisible).count
        }
        return tools + sims + artifacts
    }

    private var devToolsVisibleByteSize: Int64 {
        let tools = store.devTools
            .filter(devToolVisible)
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let sims = store.simulatorDevices
            .filter { devToolsSafetyFilter.matches($0.safetyInfo) }
            .reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let artifacts = store.projectGroups.reduce(Int64(0)) { sum, group in
            sum + group.artifacts
                .filter(projectArtifactVisible)
                .reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        return tools + sims + artifacts
    }

    private func devToolVisible(_ tool: DevTool) -> Bool {
        tool.isDetected &&
            devToolsSafetyFilter.matches(tool.safetyInfo) &&
            !store.isVisuallyRemovedBySafeCleanup(tool)
    }

    private func projectArtifactVisible(_ artifact: ProjectCacheArtifact) -> Bool {
        devToolsSafetyFilter.matches(artifact.safetyInfo) &&
            !store.isVisuallyRemovedBySafeCleanup(artifact)
    }

}

private struct DiskSummaryRefreshModifier: ViewModifier {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @EnvironmentObject private var trashStore: TrashStore

    func body(content: Content) -> some View {
        content
            .onAppear {
                diskStore.refresh()
                // This view mounts once Full Disk Access is granted, which may be long after
                // TrashStore's first pass ran blind against a trash it could not read.
                Task { await trashStore.refresh(trigger: "content-appear") }
            }
            // The user empties the trash in Finder, comes back, and the numbers update on
            // their own. Purge confirms the outcome without performing it.
            //
            // `scenePhase` is useless for this on macOS: it reports `.active` once at
            // launch and never transitions when another app takes focus (probe-proven),
            // so the app-level notifications are the only signal that actually fires.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                diskStore.markBackgrounded()
                trashStore.markBackgrounded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    // Size the trash first: the free-space note is only interpretable
                    // alongside what the trash gave up.
                    await trashStore.refresh(trigger: "foreground-return")
                    diskStore.refreshAfterForegroundReturn()
                }
            }
            // The trash total moving is the signal that Purge (or Finder) just changed
            // what is on the volume, so the chart is re-read from the same event rather
            // than from each clean path remembering to ask.
            .onChange(of: trashStore.trashBytes) { _ in
                diskStore.refresh()
            }
            .onChange(of: store.isScanningGeneral) { scanning in
                if !scanning { diskStore.refresh() }
            }
            .onChange(of: store.isScanningDeveloper) { scanning in
                if !scanning { diskStore.refresh() }
            }
            .onChange(of: store.isScanningLargeFiles) { scanning in
                if !scanning { diskStore.refresh() }
            }
            // After a clean the chart barely moves, which is the point: the bytes are
            // in the trash, still on the volume. The trash total is what changed.
            .onChange(of: store.lastDeletionReport?.id) { _ in
                if let report = store.lastDeletionReport {
                    TrashDebugLog.log(
                        "clean finished: movedToTrash=\(report.bytesMovedToTrash) "
                        + "removedDirectly=\(report.bytesRemovedDirectly) "
                        + "deleted=\(report.deletedItems.count) failed=\(report.failedItems.count)"
                    )
                }
                diskStore.refresh()
            }
    }
}

struct SidebarSummaryView: View {
    @EnvironmentObject var store: PurgeStore
    @EnvironmentObject var trashStore: TrashStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let font = Font.system(size: 12, weight: .medium, design: .rounded)

    var body: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            DeletedAppsWatcherNotice()
            if !store.hasFullDiskAccess {
                LimitedScanNotice()
            }
            trashCard
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.bottom, AppStyle.Spacing.small)
    }

    /// What is already in the Trash, as one sentence on its own card. Cleaning moves
    /// files there, so this is the figure that changes after a clean, on every tab; the
    /// Overview covers used and free space. A sentence on a card, not a label and a
    /// value in a row, so it never reads as another tab. Emptying the Trash is the
    /// user's call in Finder, so the card carries no action.
    private var trashCard: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            trashSentence
            Spacer(minLength: 0)
        }
        .font(Self.font)
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.xSmall + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(AppColors.bgElevated)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trashSentence: some View {
        switch trashStore.access {
        case .measuring:
            // The spinner holds the number's place, so the sentence does not jump.
            HStack(spacing: 4) {
                trashLoadingIndicator
                Text("in Trash").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Measuring the Trash")
        case .unreadable:
            // No Full Disk Access: the size is genuinely unknown, and a zero would
            // read as an empty Trash.
            Text("Trash size unavailable").foregroundStyle(.secondary)
        case .readable where trashStore.trashBytes <= 0:
            Text("Trash is empty").foregroundStyle(.secondary)
        case .readable:
            (Text(formatBytes(trashStore.trashBytes)).foregroundColor(.primary).fontWeight(.semibold)
                + Text(" in Trash").foregroundColor(.secondary))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: trashStore.trashBytes)
        }
    }

    @ViewBuilder
    private var trashLoadingIndicator: some View {
        if reduceMotion {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 16, height: 16)
                .tint(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(makePreviewStore())
        .environmentObject(DiskSummaryStore())
        .environmentObject(TrashStore())
}

private func makePreviewStore() -> PurgeStore {
    let store = PurgeStore()
    store.hasFullDiskAccess = true
    store.cacheItems = [
        CacheItem(
            definitionKey: "safari",
            location: CacheLocation(
                path: URL(fileURLWithPath: "/Users/preview/Library/Caches/com.apple.Safari"),
                sizeBytes: 845_000_000,
                lastModified: Date(),
                folderName: "com.apple.Safari"
            ),
            appName: "Safari",
            safetyInfo: SafetyInfo(
                level: .safe,
                headline: "Application caches are safe to remove",
                explanation: "Apps recreate cache files automatically after relaunch.",
                recoverySteps: "Reopen the app and continue using it.",
                reinstallCommand: nil
            )
        )
    ]
    return store
}
