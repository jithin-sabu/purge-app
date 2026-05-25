//
//  ContentView.swift
//  purge
//
//  Created by Jithin Sabu on 05/05/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarding.pendingCelebration") private var pendingOnboardingCelebration = false
    private let isRunningPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                if store.hasFullDiskAccess {
                    tabContent
                        .frame(minWidth: 600, minHeight: 400)
                } else {
                    PermissionPromptView {
                        store.refreshPermission()
                        if store.hasFullDiskAccess && !isRunningPreview {
                            Task { await store.scanAll() }
                        }
                    }
                }
            }
            .detailColumnCompactTop()
        }
        .task {
            guard !isRunningPreview else { return }
            guard store.hasFullDiskAccess, store.cacheItems.isEmpty, store.devTools.isEmpty, store.projectGroups.isEmpty else { return }
            await store.scanAll()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, !isRunningPreview else { return }
            Task {
                await ScheduledCleaningRegistrar.shared.runGracefulActivationSweepIfPastDue()
            }
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
        .sheet(item: $store.lastDeletionReport) { report in
            DeletionSummarySheet(
                report: report,
                onDone: {
                    store.lastDeletionReport = nil
                },
                onScanAgain: {
                    store.lastDeletionReport = nil
                    if !isRunningPreview {
                        Task { await store.scanAll() }
                    }
                }
            )
        }
        .overlay {
            if let freedBytes = store.interactiveSafeCleanupFreedBytes {
                SafeCleanupCelebrationOverlay(freedBytes: freedBytes) {
                    completeInteractiveSafeCleanupCelebration()
                }
                .transition(reduceMotion ? .opacity : .safeCleanupCelebrationBlur)
                .zIndex(90)
            }

            if let freedBytes = store.onboardingCelebrationFreedBytes {
                OnboardingCelebrationView(freedBytes: freedBytes) {
                    completeOnboardingCelebration(freedBytes: freedBytes)
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.35),
            value: store.interactiveSafeCleanupFreedBytes != nil
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
                This includes folders marked Do Not Delete and/or Not Sure. They will be removed immediately and \
                cannot be restored by Purge. Only continue if you understand the risk.
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
        .tint(AppStyle.accent)
        .modifier(DiskSummaryRefreshModifier())
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
                            systemImage: tab.icon(selected: store.selectedTab == tab),
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
        .background(AppStyle.panel)
        .sidebarCompactTop()
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            AppStyle.canvas
                .ignoresSafeArea()

            switch store.selectedTab {
            case .appCaches:
                AppCachesView(
                    items: $store.cacheItems,
                    isLoading: store.isScanningGeneral || store.isScanningAll,
                    onScan: { Task { await store.scanAll() } }
                )
            case .devTools:
                DevToolsView(
                    isLoading: store.isScanningDeveloper || store.isScanningAll,
                    onScan: { Task { await store.scanAll() } }
                )
            case .settings:
                SettingsView()
            }
        }
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
            .onChange(of: store.lastDeletionReport?.id) { _ in
                diskStore.refresh()
            }
    }
}

struct SidebarSummaryView: View {
    @EnvironmentObject var store: PurgeStore
    @EnvironmentObject var diskStore: DiskSummaryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onAppear {
            guard !store.isScanningDeveloper, !store.isScanningAll, !store.devTools.isEmpty else { return }
            store.refreshDetectedDevToolSizes()
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
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: diskStore.usedDiskBytes)

                    if safeRecoverableFraction > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppStyle.safe.opacity(0.5))
                            .frame(width: safeRecoverableFraction * width, height: 8)
                            .offset(x: max(0, (usedFraction - safeRecoverableFraction) * width))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: store.safeRecoverableBytes)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: diskStore.usedDiskBytes)
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

    private var stats: some View {
        statRow(
            symbol: SafetyLevel.safe.symbolName(filled: true),
            label: SafetyLevel.safe.displayName,
            value: formatBytes(store.safeRecoverableBytes),
            color: AppStyle.safe,
            valueColor: store.safeRecoverableBytes > 0 ? .primary : .secondary,
            animationValue: store.safeRecoverableBytes
        )
    }

    private func statRow(
        symbol: String,
        label: String,
        value: String,
        color: Color,
        valueColor: Color,
        animationValue: Int64
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(SummaryFont.label)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(SummaryFont.value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: animationValue)
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
        guard store.beginInteractiveSafeCleanup(candidates: candidates, reduceMotion: reduceMotion) else { return }

        Task { @MainActor in
            let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)
            if store.errorMessage == nil {
                store.completeInteractiveSafeCleanup(freedBytes: summary.freedBytes)
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
