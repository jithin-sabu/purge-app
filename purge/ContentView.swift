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
    @AppStorage("filter.appCaches") private var appCachesFilterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("filter.devTools") private var devToolsFilterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("filter.largeFiles") private var largeFilesCategoryFilterRaw: String = "all"
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    private let isRunningPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            sidebarDivider
            detailColumn
        }
        .task {
            await runStartupMaintenance()
        }
        .onChange(of: scenePhase) { phase in
            guard isLifecycleActive, phase == .active, !isRunningPreview else { return }
            Task {
                await ScheduledCleaningRegistrar.shared.runGracefulActivationSweepIfPastDue()
            }
        }
        .onChange(of: isLifecycleActive) { isActive in
            guard isActive else { return }
            Task { await runStartupMaintenance() }
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
                onCancel: { store.dismissLargeFileDeletionSheet() },
                onConfirm: { Task { await store.confirmLargeFileDeletion() } }
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

    private var fullDiskAccessPrompt: some View {
        PermissionPromptView {
            store.refreshPermission()
            if store.hasFullDiskAccess && !isRunningPreview {
                Task { await store.scanAll() }
            }
        }
    }

    private func scanIfNeeded() async {
        guard isLifecycleActive, !isRunningPreview else { return }
        // The menu bar model kicks off the launch scan; racing a second
        // `scanAll` here would cancel and restart it from scratch.
        guard !store.isScanningAll else { return }
        guard store.hasFullDiskAccess, store.cacheItems.isEmpty, store.devTools.isEmpty, store.projectGroups.isEmpty else { return }
        await store.scanAll()
    }

    /// Runs any past-due scheduled clean before the first scan so the UI reflects
    /// the post-clean state. `.onChange(of: scenePhase)` never fires for the initial
    /// `.active` value, so without this a cold launch would skip the activation
    /// sweep entirely and an overdue clean would sit unexecuted.
    private func runStartupMaintenance() async {
        guard isLifecycleActive, !isRunningPreview else { return }
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
                    ForEach(PurgeStore.Tab.allCases) { tab in
                        AppNavRow(
                            title: tab.rawValue,
                            systemImage: tab.icon,
                            isSelected: store.selectedTab == tab,
                            action: { store.selectedTab = tab }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppStyle.Spacing.small)

            Spacer(minLength: AppStyle.Spacing.medium)

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

    @ViewBuilder
    private var tabBody: some View {
        switch store.selectedTab {
        case .about:
            aboutTabBody
        case .appCaches:
            if store.hasFullDiskAccess {
                appCachesTabBody
            } else {
                fullDiskAccessPrompt
            }
        case .devTools:
            if store.hasFullDiskAccess {
                devToolsTabBody
            } else {
                fullDiskAccessPrompt
            }
        case .largeFiles:
            largeFilesTabBody
        case .settings:
            settingsTabBody
        }
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
                    onScan: { Task { await store.scanAll() } },
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                AppCachesView(
                    items: $store.cacheItems,
                    isLoading: store.isScanningGeneral || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { Task { await store.scanAll() } },
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
                    onScan: { Task { await store.scanAll() } },
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                DevToolsView(
                    isLoading: store.isScanningDeveloper || store.isScanningAll,
                    scanPhase: store.scanPhase,
                    onScan: { Task { await store.scanAll() } },
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
            if #available(macOS 26.0, *) {
                LargeFilesView(
                    isLoading: store.isScanningLargeFiles,
                    onScan: { Task { await store.scanLargeFiles() } },
                    showsPageHeader: false,
                    usesExternalScrollContainer: true
                )
            } else {
                LargeFilesView(
                    isLoading: store.isScanningLargeFiles,
                    onScan: { Task { await store.scanLargeFiles() } },
                    showsPageHeader: false
                )
            }
        }
        .underDetailPageHeader(includesSubtitle: true)
        .task {
            guard !isRunningPreview else { return }
            await store.scanLargeFilesIfNeeded()
        }
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
        AppSectionPageHeader(title: store.selectedTab.rawValue, subtitle: selectedPageSubtitle) {
            if store.selectedTab == .appCaches || store.selectedTab == .devTools {
                AppScanCleanActions(onScan: { Task { await store.scanAll() } }, scanPhase: store.scanPhase)
            } else if store.selectedTab == .largeFiles {
                LargeFilesHeaderActions()
            }
        }
    }

    private var selectedPageSubtitle: String? {
        switch store.selectedTab {
        case .appCaches:
            return pageSubtitle(count: appCachesSubtitleItemCount, bytes: appCachesSubtitleTotalSize)
        case .devTools:
            return pageSubtitle(count: devToolsSubtitleItemCount, bytes: devToolsSubtitleTotalSize)
        case .largeFiles:
            return largeFilesPageSubtitle
        case .settings:
            return nil
        case .about:
            return nil
        }
    }

    private func pageSubtitle(count: Int, bytes: Int64) -> String {
        let itemLabel = count == 1 ? "item" : "items"
        return "\(count) \(itemLabel) · \(formatBytes(bytes)) recoverable"
    }

    private var largeFilesVisibleForSubtitle: [LargeFile] {
        store.largeFiles.filter { file in
            largeFilesCategoryFilterRaw == "all" || file.category.rawValue == largeFilesCategoryFilterRaw
        }
    }

    private var largeFilesPageSubtitle: String {
        let files = largeFilesVisibleForSubtitle
        let bytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let fileLabel = files.count == 1 ? "file" : "files"
        return "\(files.count) \(fileLabel) · \(formatBytes(bytes)) to review"
    }

    private var appCachesSafetyFilter: SafetyFilter {
        SafetyFilter(rawValue: appCachesFilterRaw) ?? .all
    }

    private var appCachesDisplayableItems: [CacheItem] {
        store.cacheItems.filter { SafetyFilter.all.matches($0.safetyInfo) }
    }

    private var appCachesVisibleItems: [CacheItem] {
        store.cacheItems.filter {
            appCachesSafetyFilter.matches($0.safetyInfo) && !isVisuallyRemovedBySafeCleanup($0)
        }
    }

    private var appCachesSubtitleItemCount: Int {
        appCachesSafetyFilter == .all ? appCachesDisplayableItems.count : appCachesVisibleItems.count
    }

    private var appCachesSubtitleTotalSize: Int64 {
        let items = appCachesSafetyFilter == .all ? appCachesDisplayableItems : appCachesVisibleItems
        return items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var devToolsSafetyFilter: SafetyFilter {
        SafetyFilter(rawValue: devToolsFilterRaw) ?? .all
    }

    private var devToolsSubtitleItemCount: Int {
        devToolsSafetyFilter == .all ? devToolsTotalRowCount : devToolsVisibleItemCount
    }

    private var devToolsSubtitleTotalSize: Int64 {
        devToolsSafetyFilter == .all ? devToolsTotalByteSize : devToolsVisibleByteSize
    }

    private var devToolsTotalRowCount: Int {
        store.devTools.filter { $0.isDetected && $0.safetyInfo.level != .unknown }.count +
            store.simulatorDevices.filter { $0.safetyInfo.level != .unknown }.count +
            store.projectGroups.reduce(0) { sum, group in
                sum + group.artifacts.filter { $0.safetyInfo.level != .unknown }.count
            }
    }

    private var devToolsVisibleItemCount: Int {
        let tools = store.devTools.filter(devToolVisible).count
        let sims = store.simulatorDevices.filter { devToolsSafetyFilter.matches($0.safetyInfo) }.count
        let artifacts = store.projectGroups.reduce(0) { sum, group in
            sum + group.artifacts.filter(projectArtifactVisible).count
        }
        return tools + sims + artifacts
    }

    private var devToolsTotalByteSize: Int64 {
        let tools = store.devTools
            .filter { $0.isDetected && $0.safetyInfo.level != .unknown }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let sims = store.simulatorDevices
            .filter { $0.safetyInfo.level != .unknown }
            .reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let artifacts = store.projectGroups.reduce(Int64(0)) { sum, group in
            sum + group.artifacts
                .filter { $0.safetyInfo.level != .unknown }
                .reduce(Int64(0)) { $0 + $1.sizeBytes }
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
            !isVisuallyRemovedBySafeCleanup(tool)
    }

    private func projectArtifactVisible(_ artifact: ProjectCacheArtifact) -> Bool {
        devToolsSafetyFilter.matches(artifact.safetyInfo) &&
            !isVisuallyRemovedBySafeCleanup(artifact)
    }

    private func isVisuallyRemovedBySafeCleanup(_ item: CacheItem) -> Bool {
        let rowPaths = Set(item.locations.map { $0.path.standardizedFileURL.path })
        let targetedPaths = rowPaths.intersection(store.interactiveSafeCleanupTargetPaths)
        guard !targetedPaths.isEmpty else { return false }
        return targetedPaths.isSubset(of: store.interactiveSafeCleanupRemovedPaths)
    }

    private func isVisuallyRemovedBySafeCleanup(_ tool: DevTool) -> Bool {
        let rowPaths = Set(tool.paths.map { $0.standardizedFileURL.path })
        let targetedPaths = rowPaths.intersection(store.interactiveSafeCleanupTargetPaths)
        guard !targetedPaths.isEmpty else { return false }
        return targetedPaths.isSubset(of: store.interactiveSafeCleanupRemovedPaths)
    }

    private func isVisuallyRemovedBySafeCleanup(_ artifact: ProjectCacheArtifact) -> Bool {
        let path = artifact.path.standardizedFileURL.path
        return store.interactiveSafeCleanupTargetPaths.contains(path)
            && store.interactiveSafeCleanupRemovedPaths.contains(path)
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
    @EnvironmentObject var diskStore: DiskSummaryStore
    @EnvironmentObject var trashStore: TrashStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarding.pendingCelebration") private var pendingOnboardingCelebration = false
    @State private var showEmptyTrashConfirmation = false

    private enum SummaryFont {
        static let label = Font.system(size: 12, weight: .medium, design: .rounded)
        static let value = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let diskCaption = Font.system(size: 11, weight: .medium, design: .rounded)
        static let cardTitle = Font.system(size: 12, weight: .semibold, design: .rounded)
        static let heroLabel = Font.system(size: 11, weight: .semibold, design: .rounded)
        /// Qualifier sits behind the figure so the number carries the reclaimable claim.
        static let heroPrefix = Font.system(size: 13, weight: .medium, design: .rounded)
        static let hero = Font.system(size: 20, weight: .bold, design: .rounded)
    }

    var body: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            storageCard
            reclaimableCard
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.bottom, AppStyle.Spacing.small)
    }

    /// Rounded surface shared by both panels, one step above the sidebar so each card
    /// reads as its own object rather than a region of the sidebar.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            .fill(AppColors.bgElevated)
    }

    /// Volume state, reported as observation rather than as anything Purge did. Free space
    /// is the volume's business and macOS already reports it in Storage settings, so it
    /// leads the panel purely as context above the reclaimable numbers that Purge acts on.
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage")
                .font(SummaryFont.cardTitle)
                .foregroundStyle(.secondary)

            storageBar

            storageLegend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppStyle.Spacing.small)
        .background(cardBackground)
    }

    /// Safe-to-clean is the hero the Clean button honors. The trash sits below as its own
    /// secondary path with its own action, so the two never read as one summed total.
    private var reclaimableCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            cleanButton
                .padding(.top, AppStyle.Spacing.small)

            // The one hairline in this card: it sets the trash off as a separate path
            // below the primary action rather than another line of the same total.
            Divider()
                .padding(.top, AppStyle.Spacing.small)

            inTrashRow
                .padding(.top, AppStyle.Spacing.xxSmall)

            totalFootnote
                .padding(.top, AppStyle.Spacing.xxSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppStyle.Spacing.small)
        .background(cardBackground)
        .confirmationDialog(
            "Empty the trash?",
            isPresented: $showEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes everything in your Trash. It cannot be undone.")
        }
    }

    /// Safe-to-clean is what the Clean button actually moves, so it leads the card as the
    /// hero — the number carries the claim and the button below repeats it verbatim.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Safe to Clean")
                .font(SummaryFont.heroLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(heroAmountText)
                .font(SummaryFont.hero)
                .foregroundStyle(safeToCleanBytes > 0 ? .primary : .secondary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: safeToCleanBytes)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var safeToCleanBytes: Int64 {
        store.safeRecoverableBytes
    }

    private var heroAmountText: String {
        guard safeToCleanBytes > 0 else { return "0" }
        return formatBytes(safeToCleanBytes)
    }

    private var heroAccessibilityLabel: String {
        guard safeToCleanBytes > 0 else { return "Safe to clean 0" }
        return "Safe to clean \(formatBytes(safeToCleanBytes))"
    }

    /// The trash as a secondary path: same secondary-row weight as elsewhere, plus an
    /// inline outline Empty action. Structural differentiation only — no colour tiers.
    private var inTrashRow: some View {
        HStack(spacing: 6) {
            // Label and value combine into one accessibility element; the Empty button
            // stays separate so it keeps its own action and label.
            HStack(spacing: 6) {
                Text("In trash")
                    .font(SummaryFont.label)
                    .foregroundStyle(.secondary)

                Spacer()

                if trashStore.access == .measuring {
                    safeToCleanValueLoadingIndicator
                        .accessibilityLabel("Measuring")
                } else {
                    Text(formatBytes(trashStore.trashBytes))
                        .font(SummaryFont.value)
                        .foregroundStyle(trashStore.trashBytes > 0 ? .primary : .secondary)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: trashStore.trashBytes)
                }
            }
            .accessibilityElement(children: .combine)

            emptyTrashButton
        }
        .padding(.vertical, 5)
    }

    /// Outline, not filled: the one permanent action in the app reads as secondary to the
    /// reversible Clean above it. Muted border and text, trash glyph plus label.
    private var emptyTrashButton: some View {
        Button {
            showEmptyTrashConfirmation = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                Text("Empty")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!trashStore.hasTrashContents)
        .accessibilityLabel("Empty trash")
        .accessibilityHint("Permanently deletes everything in your Trash. This cannot be undone.")
    }

    /// The two-step ceiling, stated once at the foot of the card as context, not an action.
    /// Rounds down so the figure can only ever be beaten, and sums both paths at render time.
    private var reclaimableTotalBytes: Int64 {
        store.safeRecoverableBytes + trashStore.trashBytes
    }

    private var totalFootnote: some View {
        Text("up to \(formatBytesRoundedDown(reclaimableTotalBytes)) reclaimable in total")
            .font(SummaryFont.diskCaption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// TODO: connect the actual empty-trash call. No in-app permanent-delete path exists
    /// yet (it was deliberately removed previously); this stub presents the confirmed
    /// action without removing any files. See PR description.
    private func emptyTrash() {
        // Intentionally not implemented — the underlying empty-trash service call needs
        // to be built or connected.
    }

    /// Used space and free space as two segments of one volume, drawn from the same
    /// free/total figures as the legend. The fills are muted greys rather than an accent,
    /// so the bar stays observational — not progress toward a goal. The lighter used block
    /// is inset over the darker full-width track so the two segments read as one meter
    /// rather than two capsules butted together.
    private var storageBar: some View {
        GeometryReader { geo in
            // One bar split into used and free. Only the outer ends are rounded; the inner
            // edges where they meet are square, so a uniform card-coloured gap divides them
            // without tapering.
            let gap: CGFloat = 4
            let r = Self.storageBarRadius
            let usable = max(0, geo.size.width - gap)
            let usedWidth = usable * diskUsageFraction
            HStack(spacing: gap) {
                UnevenRoundedRectangle(
                    topLeadingRadius: r,
                    bottomLeadingRadius: r,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(AppColors.storageBarUsed)
                .frame(width: usedWidth)

                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: r,
                    topTrailingRadius: r,
                    style: .continuous
                )
                .fill(AppColors.storageBarFree)
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(diskUsageAccessibilityLabel)
    }

    /// Squared-off corner, not a capsule: the bar reads as a container the used block
    /// fills, matching the reference meter rather than a progress pill.
    private static let storageBarRadius: CGFloat = 6

    private var storageLegend: some View {
        HStack(spacing: 0) {
            storageLegendItem(
                color: AppColors.storageBarUsed,
                amount: formatStorageBytes(usedDiskBytes),
                suffix: "used",
                isProminent: true
            )

            Spacer(minLength: 8)

            storageLegendItem(
                color: AppColors.storageBarFree,
                amount: formatStorageBytes(diskStore.freeDiskBytes),
                suffix: "free",
                isProminent: false
            )
        }
    }

    private func storageLegendItem(
        color: Color,
        amount: String,
        suffix: String,
        isProminent: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            HStack(spacing: 0) {
                Text(amount)
                    .monospacedDigit()
                    .tracking(-0.4)

                Text(" \(suffix)")
            }
            .font(SummaryFont.diskCaption)
            .foregroundStyle(isProminent ? .secondary : .tertiary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var usedDiskBytes: Int64 {
        max(0, diskStore.totalDiskBytes - diskStore.freeDiskBytes)
    }

    private var diskUsageFraction: CGFloat {
        let total = diskStore.totalDiskBytes
        guard total > 0 else { return 0 }
        return min(1, CGFloat(Double(usedDiskBytes) / Double(total)))
    }

    private var diskUsageAccessibilityLabel: String {
        "\(formatStorageBytes(usedDiskBytes)) used of \(formatStorageBytes(diskStore.totalDiskBytes))"
    }

    @ViewBuilder
    private var safeToCleanValueLoadingIndicator: some View {
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

    private var cleanButton: some View {
        Button {
            startInteractiveSafeCleanup()
        } label: {
            CleaningButtonLabel(
                title: cleanButtonTitle,
                systemImage: nil,
                isCleaning: store.isInteractiveSafeCleanupInProgress,
                spinnerTint: AppColors.buttonPrimaryText
            )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
        .disabled(!canCleanSafeItems || store.isDeleting || store.isInteractiveSafeCleanupInProgress)
    }

    private var canCleanSafeItems: Bool {
        store.safeRecoverableBytes > 0
    }

    /// States the amount it will actually move, so a small clean reads as small rather
    /// than as a generic opportunity.
    private var cleanButtonTitle: String {
        if store.isInteractiveSafeCleanupInProgress {
            return "Cleaning..."
        }
        return canCleanSafeItems ? "Clean \(formatBytes(store.safeRecoverableBytes))" : "Nothing to clean"
    }

    private func startInteractiveSafeCleanup() {
        let candidates = store.manualSafeCleanupCandidates()
        // A pending onboarding celebration owns the post-clean screen; presenting
        // the live session too would stack two summaries on the same run.
        guard store.beginInteractiveSafeCleanup(
            candidates: candidates,
            reduceMotion: reduceMotion,
            presentsLiveSession: !pendingOnboardingCelebration
        ) else { return }

        Task { @MainActor in
            let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)
            if store.errorMessage == nil {
                store.completeInteractiveSafeCleanup(summary: summary)
            } else {
                store.cancelInteractiveSafeCleanup()
            }
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
