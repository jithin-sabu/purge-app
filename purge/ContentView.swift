//
//  ContentView.swift
//  purge
//
//  Created by Jithin Sabu on 05/05/26.
//

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

            if isLifecycleActive, let freedBytes = store.onboardingCelebrationFreedBytes {
                OnboardingCelebrationView(freedBytes: freedBytes) {
                    completeOnboardingCelebration(freedBytes: freedBytes)
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

    private func completeOnboardingCelebration(freedBytes: Int64) {
        _ = freedBytes
        pendingOnboardingCelebration = false
        store.onboardingCelebrationFreedBytes = nil
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

    func body(content: Content) -> some View {
        content
            .onAppear {
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
            .onChange(of: store.lastDeletionReport?.id) { _ in
                diskStore.refresh()
            }
    }
}

struct SidebarSummaryView: View {
    @EnvironmentObject var store: PurgeStore
    @EnvironmentObject var diskStore: DiskSummaryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarding.pendingCelebration") private var pendingOnboardingCelebration = false

    private enum SummaryFont {
        static let label = Font.system(size: 12, weight: .medium, design: .rounded)
        static let value = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let diskCaption = Font.system(size: 11, weight: .medium, design: .rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                diskBar

                stats
                    .padding(.top, AppStyle.Spacing.small)
                    .padding(.bottom, AppStyle.Spacing.small)

                cleanButton
            }
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
    }

    private var diskBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: usedFraction * width, height: 8)

                    if safeRecoverableFraction > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppColors.tagSafeBg.opacity(0.5))
                            .frame(width: safeRecoverableFraction * width, height: 8)
                            .offset(x: max(0, (usedFraction - safeRecoverableFraction) * width))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(diskBarAccessibilityLabel)

            HStack {
                Text(formatBytes(diskStore.usedDiskBytes) + " used")
                    .font(SummaryFont.diskCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(diskStore.freeDiskBytes) + " free")
                    .font(SummaryFont.diskCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diskBarAccessibilityLabel: String {
        var parts = [
            "\(formatBytes(diskStore.usedDiskBytes)) used",
            "\(formatBytes(diskStore.freeDiskBytes)) free",
        ]
        if store.safeRecoverableBytes > 0 {
            parts.append("\(formatBytes(store.safeRecoverableBytes)) safe to clean shown on disk bar")
        }
        return parts.joined(separator: ", ")
    }

    private var isSafeToCleanSummaryLoading: Bool {
        guard store.safeRecoverableBytes == 0 else { return false }
        return store.scanPhase == .scanning
            || store.scanPhase == .cancelling
            || store.isEnrichingGeneral
            || store.isEnrichingDeveloper
    }

    private var stats: some View {
        statRow(
            symbol: SafetyLevel.safe.symbolName(filled: true),
            label: SafetyLevel.safe.displayName,
            value: formatBytes(store.safeRecoverableBytes),
            color: AppColors.tagSafeText,
            valueColor: store.safeRecoverableBytes > 0 ? .primary : .secondary,
            animationValue: store.safeRecoverableBytes,
            isValueLoading: isSafeToCleanSummaryLoading
        )
    }

    private func statRow(
        symbol: String,
        label: String,
        value: String,
        color: Color,
        valueColor: Color,
        animationValue: Int64,
        isValueLoading: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 14, alignment: .center)

            Text(label)
                .font(SummaryFont.label)
                .foregroundStyle(.secondary)

            Spacer()

            if isValueLoading {
                safeToCleanValueLoadingIndicator
                    .accessibilityLabel("Scanning")
            } else {
                Text(value)
                    .font(SummaryFont.value)
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: animationValue)
            }
        }
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
                systemImage: cleanButtonSystemImage,
                isCleaning: store.isInteractiveSafeCleanupInProgress
            )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
        .disabled(!canCleanSafeItems || store.isDeleting || store.isInteractiveSafeCleanupInProgress)
    }

    private var canCleanSafeItems: Bool {
        store.safeRecoverableBytes > 0
    }

    private var cleanButtonTitle: String {
        if store.isInteractiveSafeCleanupInProgress {
            return "Cleaning..."
        }
        return canCleanSafeItems ? "Clean Safe Items" : "All clean"
    }

    private var cleanButtonSystemImage: String? {
        if store.isInteractiveSafeCleanupInProgress {
            return nil
        }
        return canCleanSafeItems ? "sparkles" : "checkmark.circle.fill"
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

    private var usedFraction: Double {
        guard diskStore.totalDiskBytes > 0 else { return 0 }
        return min(1.0, Double(diskStore.usedDiskBytes) / Double(diskStore.totalDiskBytes))
    }

    private var safeRecoverableFraction: Double {
        guard diskStore.totalDiskBytes > 0 else { return 0 }
        return min(
            usedFraction,
            Double(store.safeRecoverableBytes) / Double(diskStore.totalDiskBytes)
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(makePreviewStore())
        .environmentObject(DiskSummaryStore())
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
