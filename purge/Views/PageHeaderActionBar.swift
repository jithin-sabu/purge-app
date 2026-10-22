import SwiftUI

/// What one header button shows and does on the current tab.
struct PageHeaderAction {
    var title: String
    var systemImage: String?
    /// Swaps the icon for a spinner.
    var isBusy = false
    /// A selection's size, shown as " (size)" after the title.
    var suffixBytes: Int64?
    /// How many items are ticked, for VoiceOver when there is no size to read.
    var selectedCount = 0
    var isDisabled = false
    var help: LocalizedStringKey?
    var action: () -> Void
}

/// The two buttons at the top right of every scan page: a secondary scan button
/// and a primary clean button. They are the same two views on every tab, so moving
/// between tabs only changes their text and eases their width, the way a selection
/// grows Clean Selected; rebuilding a tab's own buttons made the header jump.
struct PageHeaderActionBar: View {
    let tab: PurgeStore.Tab
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    /// Observed here so a tick in a list updates the primary button without
    /// re-rendering the list itself.
    @ObservedObject var scanSelection: ScanSelection
    @ObservedObject var largeFileSelection: LargeFileSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingSafeClean = false

    var body: some View {
        if let secondary, let primary {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                if showsLookDeeper {
                    LookDeeperHeaderButton()
                        .transition(.opacity)
                }

                Button(action: secondary.action) {
                    MorphingActionLabel(action: secondary)
                }
                .buttonStyle(.purge(.secondary))
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(secondary.isDisabled)
                .help(secondary.help ?? "")

                Button(action: primary.action) {
                    MorphingActionLabel(action: primary)
                }
                .buttonStyle(.purge(.primary))
                .disabled(primary.isDisabled)
                .help(primary.help ?? "")
                // Only the Overview's Clean Safe Items confirms in a popover. The
                // bar stays mounted across tabs, so a tab change closes it rather
                // than leaving it beside another tab's button.
                .popover(isPresented: safeCleanConfirmationShown, arrowEdge: .bottom) {
                    safeCleanConfirmation
                }
            }
            .fixedSize()
            .onChange(of: tab) { _ in isConfirmingSafeClean = false }
            .animation(reduceMotion ? nil : MorphingActionLabel.widthAnimation, value: showsLookDeeper)
        }
    }

    private var safeCleanConfirmationShown: Binding<Bool> {
        Binding(
            get: { isConfirmingSafeClean && tab == .overview },
            set: { isConfirmingSafeClean = $0 }
        )
    }

    private var showsLookDeeper: Bool {
        !store.hasFullDiskAccess && [.overview, .appCaches, .devTools].contains(tab)
    }

    // MARK: Secondary: scan

    private var secondary: PageHeaderAction? {
        switch tab {
        case .overview:
            return overviewScan
        case .appCaches, .devTools:
            return cacheScan
        case .largeFiles:
            return store.hasFullDiskAccess ? largeFilesScan : nil
        case .uninstaller:
            return store.hasFullDiskAccess ? uninstallerScan : nil
        case .settings, .about:
            return nil
        }
    }

    /// Scan Everything runs every category scan and turns into Stop while it does.
    /// Stop leaves the App Caches and Dev Tools step to finish (it takes seconds),
    /// so once only that step is left the button just shows it is scanning.
    private var overviewScan: PageHeaderAction {
        let queue = store.scanQueue
        // A queued Everything else walk is not a category scan still to come.
        let isFinishingCacheScan = (queue.active == .cachesAndDevTools && !queue.pending.contains { $0 != .everythingElse })
            || (!queue.isRunningCategoryScan && store.isScanningAll)
        let title: String
        let systemImage: String?
        if isFinishingCacheScan {
            title = String(localized: "Scanning...")
            systemImage = nil
        } else if queue.isRunningCategoryScan {
            title = String(localized: "Stop")
            systemImage = "stop.fill"
        } else {
            title = String(localized: "Scan Everything")
            systemImage = "arrow.clockwise"
        }
        return PageHeaderAction(
            title: title,
            systemImage: systemImage,
            isBusy: isFinishingCacheScan,
            isDisabled: isFinishingCacheScan || store.isDeleting,
            help: queue.isRunningCategoryScan
                ? "Stop scanning"
                : "Scan App Caches, Dev Tools, Large Files and apps, one after another"
        ) {
            if store.scanQueue.isRunningCategoryScan {
                store.stopScans()
            } else {
                store.scanEverything()
            }
        }
    }

    private var cacheScan: PageHeaderAction {
        let isQueued = store.isScanQueued(.cachesAndDevTools)
        let phase = store.scanPhase
        let isBusy = isQueued || phase == .scanning || phase == .cancelling
        let title: String
        if isQueued {
            title = ScanQueueLabels.queued
        } else {
            switch phase {
            case .cancelling: title = String(localized: "Cancelling...")
            case .scanning: title = String(localized: "Scanning...")
            case .idle, .completed: title = String(localized: "Scan")
            }
        }
        return PageHeaderAction(
            title: title,
            systemImage: isBusy ? nil : "arrow.clockwise",
            isBusy: isBusy,
            isDisabled: isBusy
        ) {
            store.requestScan(.cachesAndDevTools)
        }
    }

    private var largeFilesScan: PageHeaderAction {
        let isScanning = store.isScanningLargeFiles
        let isQueued = !isScanning && store.isScanQueued(.largeFiles)
        let title: String
        if isQueued {
            title = ScanQueueLabels.queued
        } else {
            title = isScanning ? String(localized: "Scanning...") : String(localized: "Scan")
        }
        return PageHeaderAction(
            title: title,
            systemImage: isScanning || isQueued ? nil : "arrow.clockwise",
            isBusy: isScanning || isQueued,
            isDisabled: isScanning || isQueued
        ) {
            store.requestScan(.largeFiles)
        }
    }

    /// Rescan refreshes every list on this tab, so the button reflects any of them.
    private var uninstallerScan: PageHeaderAction {
        let isScanning = store.isScanningInstalledApps || store.isScanningOrphans || store.isScanningCommandLineTools
        let isQueued = !isScanning && (store.isScanQueued(.apps) || store.isScanQueued(.leftovers)
            || store.isScanQueued(.commandLineTools))
        let title: String
        if isQueued {
            title = ScanQueueLabels.queued
        } else {
            title = isScanning ? String(localized: "Scanning...") : String(localized: "Rescan")
        }
        return PageHeaderAction(
            title: title,
            systemImage: isScanning || isQueued ? nil : "arrow.clockwise",
            isBusy: isScanning || isQueued,
            isDisabled: isScanning || isQueued
        ) {
            store.requestScan(.apps, .leftovers, .commandLineTools)
        }
    }

    // MARK: Primary: clean

    private var primary: PageHeaderAction? {
        switch tab {
        case .overview:
            return overviewCleanSafe
        case .appCaches, .devTools:
            return cleanSelected
        case .largeFiles:
            return store.hasFullDiskAccess ? deleteSelectedLargeFiles : nil
        case .uninstaller:
            return store.hasFullDiskAccess ? uninstallerPrimary : nil
        case .settings, .about:
            return nil
        }
    }

    /// Moves every Safe App Caches and Dev Tools item to the Trash, after a short
    /// confirmation. The title carries no size on purpose: beside the category
    /// totals on the Overview a smaller figure reads as a mistake, and the popover
    /// gives the amount next to the total it comes from. With nothing Safe left it
    /// stays in place, disabled, so the header keeps its two buttons.
    private var overviewCleanSafe: PageHeaderAction {
        let isCleaning = store.isInteractiveSafeCleanupInProgress
        // The figure moves while either scan runs, so the button waits for both.
        let isReady = store.isSettled(.appCaches) && store.isSettled(.devTools)
        return PageHeaderAction(
            title: isCleaning ? String(localized: "Cleaning...") : String(localized: "Clean Safe Items"),
            systemImage: isCleaning ? nil : "trash.fill",
            isBusy: isCleaning,
            isDisabled: store.safeRecoverableBytes == 0 || !isReady || store.isDeleting || isCleaning,
            help: isReady
                ? "Move every Safe item in App Caches and Dev Tools to the Trash"
                : "Waiting for App Caches and Dev Tools to finish scanning"
        ) {
            isConfirmingSafeClean = true
        }
    }

    private var cleanSelected: PageHeaderAction {
        let count = store.selectedCount
        return PageHeaderAction(
            title: String(localized: "Clean Selected"),
            systemImage: "trash.fill",
            suffixBytes: count > 0 ? store.selectedTotalBytes : nil,
            selectedCount: count,
            isDisabled: count == 0 || store.isDeleting
        ) {
            store.showDeletionSheet = true
        }
    }

    private var deleteSelectedLargeFiles: PageHeaderAction {
        let count = store.selectedLargeFileCount
        return PageHeaderAction(
            title: String(localized: "Delete Selected"),
            systemImage: "trash.fill",
            suffixBytes: count > 0 ? store.selectedLargeFileBytes : nil,
            selectedCount: count,
            isDisabled: count == 0 || store.isDeleting
        ) {
            store.presentLargeFileDeletionSheet()
        }
    }

    /// Uninstall for the apps, Remove for leftovers and command-line tools. Apps
    /// show no size: the review sheet owns the exact total there.
    private var uninstallerPrimary: PageHeaderAction {
        let section = store.uninstallSection
        if section == .installedApps, store.isBuildingUninstallPlan {
            return PageHeaderAction(
                title: String(localized: "Preparing..."),
                isBusy: true,
                isDisabled: true
            ) {}
        }
        let title: String
        let selectedCount: Int
        let selectedBytes: Int64?
        let isDisabled: Bool
        switch section {
        case .installedApps:
            title = String(localized: "Uninstall")
            selectedCount = store.selectedApps.count
            selectedBytes = nil
            isDisabled = store.selectedAppIDs.isEmpty
        case .leftovers:
            title = String(localized: "Remove")
            selectedCount = store.selectedOrphanCount
            selectedBytes = store.selectedOrphanBytes
            isDisabled = selectedCount == 0
        case .commandLineTools:
            title = String(localized: "Remove")
            selectedCount = store.selectedCommandLineToolCount
            selectedBytes = store.selectedCommandLineToolBytes
            isDisabled = selectedCount == 0
        }
        return PageHeaderAction(
            title: title,
            systemImage: "trash.fill",
            suffixBytes: selectedCount > 0 ? selectedBytes : nil,
            selectedCount: selectedCount,
            isDisabled: isDisabled || store.isDeleting
        ) {
            switch section {
            case .installedApps: Task { await store.requestUninstallSelectedApps() }
            case .leftovers: store.requestOrphanCleanup()
            case .commandLineTools: store.requestCommandLineToolRemoval()
            }
        }
    }

    private var safeCleanConfirmation: some View {
        OverviewCleanSafeConfirmation(
            breakdown: store.overviewBreakdown(
                totalBytes: diskStore.totalDiskBytes,
                freeBytes: diskStore.freeDiskBytes
            ),
            onCancel: { isConfirmingSafeClean = false },
            onConfirm: {
                isConfirmingSafeClean = false
                store.cleanSafeItemsFromOverview(reduceMotion: reduceMotion)
            },
            onReview: { category in
                isConfirmingSafeClean = false
                store.openFromOverview(category)
            }
        )
        .environmentObject(store)
    }
}

/// A header button's icon and text. The text rolls like the app's numbers when
/// it changes, and the label eases to its new width instead of snapping, so a
/// button keeps its place while its content changes.
struct MorphingActionLabel: View {
    let action: PageHeaderAction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredWidth: CGFloat?

    static let widthAnimation: Animation = .spring(response: 0.38, dampingFraction: 0.92, blendDuration: 0.12)
    private static let textAnimation: Animation = .easeInOut(duration: 0.4)

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .fixedSize()

            content
                .fixedSize()
                .hidden()
                .background(MorphingActionWidthReader())
                .accessibilityHidden(true)
        }
        .frame(width: measuredWidth, alignment: .leading)
        .clipped()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .onPreferenceChange(MorphingActionWidthKey.self) { width in
            guard width > 0 else { return }
            if reduceMotion || measuredWidth == nil {
                measuredWidth = width
            } else {
                withAnimation(Self.widthAnimation) {
                    measuredWidth = width
                }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            icon
            HStack(spacing: 0) {
                Text(LocalizedStringKey(action.title))
                    .contentTransition(reduceMotion ? .identity : .numericText())
                if let bytes = action.suffixBytes {
                    HStack(spacing: 0) {
                        Text(" (")
                        Text(formatBytes(bytes))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        Text(")")
                    }
                    .transition(suffixTransition)
                }
            }
        }
        .animation(reduceMotion ? nil : Self.textAnimation, value: action.title)
        .animation(reduceMotion ? nil : Self.textAnimation, value: action.suffixBytes)
        .animation(reduceMotion ? nil : Self.textAnimation, value: action.systemImage)
        .animation(reduceMotion ? nil : Self.textAnimation, value: action.isBusy)
    }

    @ViewBuilder
    private var icon: some View {
        if action.isBusy {
            Group {
                if reduceMotion {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 13, height: 13)
                }
            }
            .transition(.opacity)
        } else if let systemImage = action.systemImage {
            Image(systemName: systemImage)
                .id(systemImage)
                .transition(.opacity)
        }
    }

    /// The suffix is revealed as the label grows. On exit the label shrinks, which
    /// would drag the fading suffix over the title, so it leaves toward the
    /// trailing edge instead.
    private var suffixTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity,
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    private var accessibilityTitle: String {
        let title = String(localized: String.LocalizationValue(action.title))
        if let bytes = action.suffixBytes {
            return String(localized: "\(title), \(formatBytes(bytes)) selected")
        }
        // Uninstall shows no size (the review sheet owns the total), so the
        // count is what VoiceOver reads.
        guard action.selectedCount > 0 else { return title }
        return String(localized: "\(title), \(action.selectedCount) selected")
    }
}

private struct MorphingActionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MorphingActionWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MorphingActionWidthKey.self, value: proxy.size.width)
        }
    }
}
