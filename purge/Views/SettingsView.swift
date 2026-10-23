import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var updater: PurgeUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var prefs = ScheduledCleaningPreferenceStore.shared
    @ObservedObject private var startup = StartupPreferenceStore.shared
    @ObservedObject private var helper = PrivilegedHelperPreferenceStore.shared
    @ObservedObject private var registrar = ScheduledCleaningRegistrar.shared
    @ObservedObject private var history = CleanupHistoryStore.shared
    @ObservedObject private var removedApps = RemovedAppMonitor.shared
    @ObservedObject private var finderService = FinderServicePreference.shared
    @AppStorage(DevToolsStalenessOption.userDefaultsKey)
    private var devToolsStalenessThresholdRaw = DevToolsStalenessOption.defaultOption.rawValue
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(DeveloperMode.userDefaultsKey)
    private var developerModeEnabled = false
    var showsPageHeader = true
    /// When true, the parent owns scrolling and the macOS 26 progressive scroll-edge blur.
    var usesExternalScrollContainer = false

    @State private var loginItemFailure: LoginItemFailure?
    @State private var isRunningScheduledCleanNow = false
    @State private var scheduledCleanNowMessage: String?
    @State private var showClearHistoryConfirmation = false
    @State private var showExcludedFoldersSheet = false
    @State private var showCleaningHistorySheet = false
    @State private var showCustomIntervalSheet = false
    @State private var selectedHistoryEntry: CleanupHistoryEntry?
    /// Session cache of on-disk sizes for excluded paths, keyed by path. No entry
    /// means the size is still loading.
    @State private var excludedPathSizes: [String: ExcludedPathSize] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: showsPageHeader ? 28 : 0) {
                if showsPageHeader {
                    Text("Settings")
                        .font(AppStyle.Typography.pageTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Four groups, one line per setting. The longer explanations sit
                // behind an info button beside each title, and the two lists
                // (exclusions, history) open in a sheet.
                VStack(alignment: .leading, spacing: 18) {
                    generalGroup
                    cleaningGroup
                    uninstallingGroup
                    updatesAndHistoryGroup
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, settingsHorizontalContentInset)
        .padding(.top, contentTopPadding)
        .padding(.bottom, contentBottomPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: usesExternalScrollContainer ? nil : .infinity, alignment: .topLeading)
        .background(AppColors.surfaceBase)
        .onAppear {
            startup.refreshLoginItemStatus()
            helper.refresh()
        }
        // The user can turn the login item off in System Settings without telling
        // us; re-read on the way back in so the switch isn't stale. The privileged
        // helper is enabled in that same pane, so re-read it here too.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startup.refreshLoginItemStatus()
            clearLoginItemFailureIfResolved()
            helper.refresh()
        }
        .sheet(isPresented: $showExcludedFoldersSheet) {
            excludedFoldersSheet
        }
        .sheet(isPresented: $showCleaningHistorySheet) {
            cleaningHistorySheet
        }
        .onChange(of: devToolsStalenessThresholdRaw) { _ in
            // Through the queue, so it waits its turn behind a running scan.
            store.requestScan(.cachesAndDevTools)
        }
        .alert(
            "Scheduled clean",
            isPresented: Binding(
                get: { scheduledCleanNowMessage != nil },
                set: { if !$0 { scheduledCleanNowMessage = nil } }
            )
        ) {
            Button("OK") { scheduledCleanNowMessage = nil }
        } message: {
            Text(scheduledCleanNowMessage ?? "")
        }
    }

    /// The four states the secure-removal helper can be in. Held as one value so the
    /// status line's icon, tint, message and action stay in lockstep, and so the
    /// layout can animate on a single `Equatable` key as the state changes.
    private enum HelperPhase: Equatable {
        case on
        case awaitingApproval
        case failed
        case off
    }

    private var helperPhase: HelperPhase {
        if helper.isEnabled { return .on }
        if helper.needsApproval { return .awaitingApproval }
        if helper.lastRegistrationFailed { return .failed }
        return .off
    }

    // MARK: - General

    private var generalGroup: some View {
        settingsGroup("General") {
            settingsToggleRow(
                title: String(localized: "Keep Purge in the menu bar"),
                caption: menuBarModeCaption,
                captionAnimatesTextChanges: true,
                isOn: Binding(
                    get: { startup.showsMenuBarIcon },
                    set: { shown in
                        // A failed switch leaves the menu bar mode on and the login
                        // row showing, so the warning lands under the row at fault.
                        loginItemFailure = startup.setShowsMenuBarIcon(shown) ? nil : .disable
                    }
                )
            )

            // Both only make sense with an icon to click, so they are not offered
            // without one. Leaving the menu bar turns them off (`setShowsMenuBarIcon`).
            if startup.showsMenuBarIcon {
                Group {
                    settingsSectionDivider

                    settingsToggleRow(
                        title: String(localized: "Launch Purge at login"),
                        caption: String(localized: "Starts quietly in the menu bar."),
                        warning: loginItemFailure?.message,
                        isOn: launchAtLoginBinding
                    )

                    settingsSectionDivider

                    settingsToggleRow(
                        title: String(localized: "Hide Dock icon"),
                        // Only true while the icon is hidden: with it shown, the app
                        // menu is back and ⌘Q quits.
                        caption: startup.hidesDockIcon
                            ? String(localized: "Quit from the menu bar, since ⌘Q won't work.")
                            : nil,
                        info: String(localized: """
                            Purge runs from the menu bar only. Click the menu bar icon to open \
                            this window again. The app menu is gone while the Dock icon is \
                            hidden, so ⌘Q won't quit. Use Quit in the menu bar dropdown.
                            """),
                        captionAnimatesTextChanges: true,
                        isOn: hideDockIconBinding
                    )
                }
                .transition(.opacity)
            }

            settingsSectionDivider

            settingsControlRow(title: String(localized: "Appearance")) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        AppearanceOptionButton(
                            mode: mode,
                            isSelected: currentAppearanceMode == mode
                        ) {
                            appearanceModeRaw = mode.rawValue
                        }
                    }
                }
            }
        }
        .animation(scheduleLayoutAnimation, value: startup.showsMenuBarIcon)
    }

    private var menuBarModeCaption: String {
        startup.showsMenuBarIcon
            ? String(localized: "Keeps running after you close the window.")
            : String(localized: "Quits when you close the window.")
    }

    // MARK: - Cleaning

    private var cleaningGroup: some View {
        settingsGroup("Cleaning") {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                settingsControlRow(
                    title: String(localized: "Clean automatically"),
                    caption: autoCleanCaption(referenceDate: context.date),
                    info: scheduleSummary,
                    animatesCaptionChanges: true
                ) {
                    HStack(spacing: AppStyle.Spacing.small) {
                        SettingsMenuPicker(
                            selection: frequencySelectionBinding,
                            options: ScheduledCleaningFrequency.allCases,
                            optionLabel: \.displayName,
                            accessibilityTitle: String(localized: "How often")
                        )
                        .disabled(!prefs.isEnabled)

                        Toggle(String(localized: "Clean automatically"), isOn: autoCleanEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(AppColors.statusSafeText)
                    }
                }
            }
            .sheet(isPresented: $showCustomIntervalSheet) {
                CustomCleaningIntervalSheet(
                    initialAmount: prefs.customIntervalAmount,
                    initialUnit: prefs.customIntervalUnit,
                    onCancel: { showCustomIntervalSheet = false },
                    onConfirm: { amount, unit in
                        prefs.customIntervalAmount = amount
                        prefs.customIntervalUnit = unit
                        prefs.frequency = .custom
                        showCustomIntervalSheet = false
                    }
                )
            }

            if prefs.isEnabled && developerModeEnabled {
                settingsSectionDivider

                runScheduledCleanNowRow
            }

            settingsSectionDivider

            settingsPickerRow(
                title: String(localized: "Projects count as stale after"),
                info: currentDevToolsStalenessOption.description,
                selection: devToolsStalenessSelectionBinding,
                options: DevToolsStalenessOption.allCases,
                optionLabel: \.label
            )

            settingsSectionDivider

            settingsLinkRow(
                title: String(localized: "Excluded folders"),
                value: excludedFoldersSummary
            ) {
                showExcludedFoldersSheet = true
            }
        }
    }

    /// One line: what it does, and when it next runs.
    private func autoCleanCaption(referenceDate: Date) -> String {
        guard prefs.isEnabled else {
            return String(localized: "Moves Safe items to the Trash on a schedule.")
        }
        let next = nextCleanDisplay(referenceDate: referenceDate).primary
        return String(localized: "Moves Safe items to the Trash. Next: \(next).")
    }

    private var excludedFoldersSummary: String {
        let count = excludedEntries.count
        switch count {
        case 0: return String(localized: "None")
        case 1: return String(localized: "1 folder")
        default: return String(localized: "\(count) folders")
        }
    }

    // MARK: - Uninstalling

    private var uninstallingGroup: some View {
        settingsGroup("Uninstalling") {
            settingsToggleRow(
                title: String(localized: "Uninstall from Finder's right-click menu"),
                info: finderServiceCaption,
                warning: finderService.flushFailed ? finderServiceFlushWarning : nil,
                isToggleDisabled: finderService.isApplying,
                isOn: Binding(
                    get: { finderService.isEnabled },
                    set: { enabled in Task { await finderService.setEnabled(enabled) } }
                )
            )
            // The same switch lives in System Settings, so read it again each time
            // this page comes into view.
            .onAppear { finderService.refresh() }

            settingsSectionDivider

            // A watcher macOS blocked or that stopped misses every removal in
            // silence, so its state shows under the title, with the one fix.
            settingsToggleRow(
                title: String(localized: "Review leftovers when an app is deleted"),
                info: deletedAppsCaption,
                status: deletedAppsStatus,
                isOn: Binding(
                    get: { removedApps.isEnabled },
                    set: { removedApps.setEnabled($0) }
                )
            )
            .onAppear { removedApps.refreshAgentStatus() }

            settingsSectionDivider

            // A switch, like every other setting, so the control never changes shape
            // between states. Turning it on registers the helper (which then waits on
            // approval in System Settings); turning it off unregisters it.
            settingsToggleRow(
                title: String(localized: "Remove admin-locked apps without a password"),
                info: helperCaption,
                status: helperStatus,
                isOn: helperEnabledBinding
            )
        }
    }

    private var deletedAppsStatus: SettingsRowStatus? {
        // The switch already says on or off; a line only appears when the
        // watcher needs a fix.
        let health = removedApps.watcherHealth
        switch health {
        case .off, .checking, .running:
            return nil
        case .needsApproval, .notRunning, .failedToStart:
            return SettingsRowStatus(
                text: deletedAppsStatusMessage(health),
                tint: AppColors.statusCheckText,
                showsProgress: removedApps.isRestartingWatcher,
                actionTitle: health.fixTitle.map { removedApps.isRestartingWatcher ? String(localized: "Restarting…") : $0 },
                isActionDisabled: removedApps.isRestartingWatcher,
                action: { removedApps.fixWatcher() }
            )
        }
    }

    private var helperStatus: SettingsRowStatus? {
        // As for the watcher: no line while all is well.
        switch helperPhase {
        case .off, .on:
            return nil
        case .awaitingApproval:
            return SettingsRowStatus(
                text: helperStatusMessage,
                tint: AppColors.statusCheckText,
                actionTitle: String(localized: "Open System Settings"),
                action: { helper.openLoginItemsSettings() }
            )
        case .failed:
            return SettingsRowStatus(text: helperStatusMessage, tint: AppColors.statusCheckText)
        }
    }

    // MARK: - Updates and history

    private var updatesAndHistoryGroup: some View {
        settingsGroup("Updates and History") {
            settingsToggleRow(
                title: String(localized: "Check for updates automatically"),
                info: updatesSummary,
                isOn: automaticUpdateChecksBinding
            )

            settingsSectionDivider

            settingsToggleRow(
                title: String(localized: "Install updates automatically"),
                info: automaticInstallSummary,
                isToggleDisabled: !updater.allowsAutomaticUpdates,
                isOn: automaticUpdateDownloadsBinding
            )

            settingsSectionDivider

            // Ticks each minute so "Today" turns into "Yesterday" past midnight.
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                settingsLinkRow(
                    title: String(localized: "Cleaning history"),
                    value: lastCleanSummary(referenceDate: context.date),
                    valueIsFigure: true
                ) {
                    showCleaningHistorySheet = true
                }
            }
        }
    }

    /// The same figure the History sheet shows for the entry: trashed plus
    /// permanently deleted bytes, the measured gain for the Apple Intelligence
    /// models, or what removed iCloud downloads freed. The last two move nothing
    /// to the Trash.
    private func lastCleanSummary(referenceDate: Date) -> String {
        guard let latest = history.archive.entries.first else {
            return String(localized: "None yet")
        }
        let relative = relativeDateText(for: latest.date, referenceDate: referenceDate)
        let removedNothing: Bool
        switch latest.kind {
        case nil:
            removedNothing = latest.bytesMovedToTrash + latest.bytesDeletedPermanently == 0
        case .appleIntelligenceModels?, .iCloudDownloadsRemoved?:
            removedNothing = false
        }
        guard !removedNothing else {
            return String(localized: "Last: nothing moved, \(relative)")
        }
        let figure = CleanupHistorySummaryRow(entry: latest).primaryFigure
        return String(localized: "Last: \(figure), \(relative)")
    }

    /// Verification affordance: runs the real scheduled-clean pipeline now (same
    /// safe rules and staleness thresholds) so users don't have to wait out a full
    /// interval to confirm automatic cleaning works.
    private var runScheduledCleanNowRow: some View {
        settingsControlRow(
            title: String(localized: "Test the schedule"),
            caption: String(localized: "Runs a scheduled clean now. It counts as this period's clean.")
        ) {
            runScheduledCleanNowButton
        }
    }

    private var runScheduledCleanNowButton: some View {
        Button(action: runScheduledCleanNow) {
            HStack(spacing: 6) {
                if isRunningScheduledCleanNow {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isRunningScheduledCleanNow ? LocalizedStringKey("Cleaning…") : LocalizedStringKey("Run now"))
            }
        }
        .buttonStyle(.purge(.secondary))
        .disabled(isRunningScheduledCleanNow || store.isDeleting)
    }

    private func runScheduledCleanNow() {
        guard !isRunningScheduledCleanNow else { return }
        isRunningScheduledCleanNow = true
        Task {
            let summary = await ScheduledCleaningRegistrar.shared.runScheduledCleanNow()
            isRunningScheduledCleanNow = false
            scheduledCleanNowMessage = Self.scheduledCleanNowMessage(for: summary)
        }
    }

    /// What the Run now alert says. Each way a run can end with nothing moved has
    /// its own line, so "nothing matched" is only said when that is what happened (#173).
    static func scheduledCleanNowMessage(
        for summary: PurgeStore.ScheduledCleaningSummary?
    ) -> String {
        guard let summary else {
            return String(localized: "Auto-clean is off, so nothing ran. Turn it on and try again.")
        }
        if summary.skippedForAnotherClean {
            return String(localized: "Purge is already cleaning, or a review is open. Wait for it to finish, then try again.")
        }
        if summary.failed {
            return String(localized: "The clean couldn't finish, so nothing was moved. Try again in a moment.")
        }
        if summary.deletedCount == 0 {
            return String(localized: """
            Nothing matched your safe settings right now — the schedule is working, there just \
            wasn't anything safe to clean yet.
            """)
        }
        let noun = summary.deletedCount == 1 ? String(localized: "item") : String(localized: "items")
        return String(localized: "Moved \(summary.deletedCount) \(noun) to Trash, about \(formatBytes(summary.bytesMovedToTrash)). Empty the trash to reclaim the space.")
    }

    // MARK: - Sheets

    /// Scans skip these folders and everything inside them. Purely subtractive:
    /// un-excluding only restores eligibility when the path still passes the normal
    /// allowlist gate.
    var excludedFoldersSheet: some View {
        settingsSheet(
            title: String(localized: "Excluded folders"),
            caption: String(localized: "Scans skip these folders and everything inside them. You can also right-click a scan result and choose Exclude from scans."),
            onDone: { showExcludedFoldersSheet = false }
        ) {
            Button(action: chooseFoldersToExclude) {
                Label("Add folder\u{2026}", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.purge(.secondary))
        } content: {
            let entries = excludedEntries
            settingsSectionCard {
                if entries.isEmpty {
                    Text("Nothing excluded")
                        .font(scheduleStatusPrimaryFont)
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(16)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.path) { index, entry in
                        if index > 0 {
                            settingsSectionDivider
                        }
                        excludedPathRow(entry: entry)
                    }

                    settingsSectionDivider

                    excludedTotalRow(entries: entries)
                }
            }
        }
    }

    /// Recent cleanup activity, so scheduled cleans are visible in the app instead
    /// of only in a passing notification.
    var cleaningHistorySheet: some View {
        settingsSheet(
            title: String(localized: "Cleaning history"),
            caption: nil,
            onDone: { showCleaningHistorySheet = false }
        ) {
            // Quiet: it asks for confirmation before anything happens, so it
            // shouldn't pull the eye from Done.
            Button("Clear history") {
                showClearHistoryConfirmation = true
            }
            .buttonStyle(.purge(.quiet, size: .small))
            .disabled(history.archive.entries.isEmpty)
        } content: {
            settingsSectionCard {
                if history.archive.entries.isEmpty {
                    Text("No cleans recorded yet. Automatic and manual cleans will show up here.")
                        .font(scheduleStatusSecondaryFont)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                } else {
                    ForEach(Array(history.archive.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            settingsSectionDivider
                        }
                        Button {
                            selectedHistoryEntry = entry
                        } label: {
                            CleanupHistorySummaryRow(entry: entry)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selectedHistoryEntry) { entry in
            CleanupHistoryDetailView(entry: entry)
        }
        .confirmationDialog(
            "Clear cleaning history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                history.clear()
                CleanupLedgerStore.shared.clear(
                    keepingTotal: store.totalMovedToTrashBytes,
                    firstSeenAt: UserDefaults.standard.object(forKey: FirstRunGate.firstSeenAtKey) as? Date
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved cleanup records from this Mac. It cannot be undone.")
        }
    }

    /// A titled sheet with a scrolling list, an action at the top, and Done.
    private func settingsSheet<Action: View, Content: View>(
        title: String,
        caption: String?,
        onDone: @escaping () -> Void,
        @ViewBuilder action: () -> Action,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
                    Text(LocalizedStringKey(title))
                        .font(AppStyle.Typography.sectionTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    action()
                }

                // Full width under the title row, so it isn't squeezed beside
                // the button.
                if let caption {
                    Text(LocalizedStringKey(caption))
                        .settingsCaption()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ScrollView {
                content()
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 560, height: 480)
        .background(AppColors.surfaceBase)
    }

    private var helperCaption: String {
        String(localized: """
        Some apps are installed under an administrator and can't be moved to the Trash on their \
        own, and neither can the files a finished macOS update leaves behind. Purge asks you to \
        enable its secure removal helper only when something needs it. Items still go to the \
        Trash, and you can turn it off here at any time.
        """)
    }

    /// The switch reads on for both `.on` and `.awaitingApproval`: once the user asks
    /// for the helper, its intent stays on while System Settings approval is pending,
    /// and turning the switch back off during that wait cancels the request.
    private var helperEnabledBinding: Binding<Bool> {
        Binding(
            get: { helper.isEnabled || helper.needsApproval },
            set: { helper.setEnabled($0) }
        )
    }

    private var helperStatusMessage: String {
        switch helperPhase {
        case .on:
            return String(localized: "On. Admin-locked apps can be moved to the Trash without a password.")
        case .awaitingApproval:
            return String(localized: "Approval is still needed in System Settings.")
        case .failed:
            return String(localized: "Setup didn't complete. Turn it on again to retry.")
        case .off:
            return String(localized: "Off. Purge will ask for approval the first time an app needs it.")
        }
    }

    private var currentAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { startup.launchesAtLogin },
            set: { newValue in
                loginItemFailure = startup.setLaunchesAtLogin(newValue)
                    ? nil
                    : (newValue ? .enable : .disable)
            }
        )
    }

    /// The warning outlives the attempt that caused it, so it has to go once the
    /// user has fixed things in System Settings, or it sits under a switch that
    /// now shows the state they asked for.
    private func clearLoginItemFailureIfResolved() {
        switch loginItemFailure {
        case .enable where startup.launchesAtLogin, .disable where !startup.launchesAtLogin:
            loginItemFailure = nil
        default:
            break
        }
    }

    private var hideDockIconBinding: Binding<Bool> {
        Binding(
            get: { startup.hidesDockIcon },
            set: { startup.setHidesDockIcon($0) }
        )
    }

    /// The setting is saved, but Finder reads it through a cache Purge could
    /// not clear, so the menu lags until macOS rebuilds it at login.
    private var finderServiceFlushWarning: String {
        String(localized: "Saved, but Finder may keep showing the old state until you log out and back in.")
    }

    private var finderServiceCaption: String {
        String(localized: """
        Right-click an app in Finder and choose Uninstall with Purge. Purge opens \
        with that app and everything it left behind, ready to review. macOS keeps \
        this off until you turn it on here, or under System Settings > Keyboard > \
        Keyboard Shortcuts > Services. Dropping an app on Purge's Dock icon does \
        the same and needs no setup.
        """)
    }

    private var deletedAppsCaption: String {
        String(localized: """
        When an app leaves Applications, like dragging it to the Trash in Finder, \
        Purge opens with the files it left behind, even if Purge was quit. Nothing \
        moves until you confirm. A small background watcher stays on while this is \
        enabled; you can turn it off here at any time.
        """)
    }

    private func deletedAppsStatusMessage(_ health: WatcherHealth) -> String {
        switch health {
        case .off:
            return String(localized: "Off. Apps deleted outside Purge are not noticed.")
        case .checking:
            return String(localized: "Checking the background watcher.")
        case .running:
            return String(localized: "On. Purge is watching for deleted apps.")
        case .notRunning:
            // A restart that does not stick means something outside Purge stops
            // the watcher, so point at the switch macOS keeps for it.
            return (health.problemMessage ?? "")
                + String(localized: " If it stops again, check that Purge is switched on under Login Items in System Settings.")
        case .needsApproval, .failedToStart:
            return health.problemMessage ?? ""
        }
    }

    private var updatesSummary: String {
        String(localized: """
        Purge checks once a day. When automatic installs are off, a new version opens the \
        update window. Every download is signature-checked.
        """)
    }

    private var automaticInstallSummary: String {
        String(localized: """
        New versions download in the background and install when Purge quits, or right away \
        with Restart to Update in the Purge menu. When this is off, nothing is installed \
        without your confirmation.
        """)
    }

    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    /// Shows off while checks are off, since Sparkle won't download then even
    /// if the setting underneath is still on.
    private var automaticUpdateDownloadsBinding: Binding<Bool> {
        Binding(
            get: { updater.allowsAutomaticUpdates && updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }
        )
    }

    private var excludedEntries: [ExcludedPathEntry] {
        ExcludedPathsStore.allEntries()
    }

    private func excludedPathRow(entry: ExcludedPathEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Bundle.main.localizedString(forKey: CacheHeadline.localized(entry.displayName, cacheFolder: (entry.path as NSString).lastPathComponent, appFolder: CacheHeadline.applicationSupportAppFolder(of: entry.path)), value: nil, table: "Explanations"))
                    .font(scheduleStatusPrimaryFont)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Text(entry.path)
                    .font(AppStyle.Typography.micro.weight(.regular).monospaced())
                    .foregroundStyle(AppColors.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            excludedSizeLabel(forPath: entry.path)

            Button {
                removeExclusion(entry: entry)
            } label: {
                Label("Remove \(entry.displayName)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
            }
            .buttonStyle(.purge(.secondary, size: .small, width: .square))
            .help("Remove from exclusions. \(entry.displayName) is scanned again next time.")
        }
        .padding(16)
        .task(id: entry.path) {
            await loadExcludedSizeIfNeeded(forPath: entry.path)
        }
    }

    @ViewBuilder
    private func excludedSizeLabel(forPath path: String) -> some View {
        switch excludedPathSizes[path] {
        case .measured(let bytes):
            excludedSizeText(formatBytes(bytes))
        case .missing:
            excludedSizeText(String(localized: "Not found"))
        case .unmeasurable:
            excludedSizeText(String(localized: "Can\u{2019}t measure"))
                .help("Purge couldn\u{2019}t read this folder to measure it. It\u{2019}s still excluded.")
        case nil:
            SkeletonBar(width: 56, height: 12)
                .shimmering()
        }
    }

    private func excludedSizeText(_ text: String) -> some View {
        Text(text)
            .font(scheduleStatusSecondaryFont.numbers)
            .foregroundStyle(AppColors.textSecondary)
            .monospacedDigit()
    }

    private func excludedTotalRow(entries: [ExcludedPathEntry]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Total")
                .font(scheduleStatusPrimaryFont)
                .foregroundStyle(AppColors.textSecondary)

            Spacer(minLength: 12)

            let total = ExcludedPathsTotal.compute(paths: entries.map(\.path), sizes: excludedPathSizes)
            if total.isComplete {
                // A folder `du` couldn't read makes the sum a floor, not a total.
                Text(total.hasUnmeasured ? String(localized: "At least \(formatBytes(total.bytes))") : formatBytes(total.bytes))
                    .font(scheduleStatusPrimaryFont.numbers)
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
            } else {
                // Summing while rows still load would show a number that looks final.
                SkeletonBar(width: 72, height: 14)
                    .shimmering()
            }
        }
        .padding(16)
    }

    private func loadExcludedSizeIfNeeded(forPath path: String) async {
        guard excludedPathSizes[path] == nil else { return }
        let url = URL(fileURLWithPath: path)
        let size = await Task.detached(priority: .utility) { () -> ExcludedPathSize in
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            // Not `directoryByteSize`, which reports a failed reading as 0.
            return FolderSizing.directoryByteSizeIfMeasurable(at: url).map(ExcludedPathSize.measured) ?? .unmeasurable
        }.value
        // Removed while it was measuring: writing the size back would leave a stale
        // figure that a re-add in this session would show instead of measuring again.
        guard store.excludedPaths.contains(path) else { return }
        excludedPathSizes[path] = size
    }

    /// Lets someone exclude a folder before it ever shows up in a scan, which is the
    /// usual case for an archive kept on purpose (#46). A plain panel, not a sheet:
    /// Settings can be embedded in the main window or live in its own.
    private func chooseFoldersToExclude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Exclude")
        panel.message = String(localized: "Purge won\u{2019}t scan or clean anything inside the folders you choose.")
        panel.begin { response in
            guard response == .OK else { return }
            store.excludeFoldersFromScans(panel.urls)
        }
    }

    private func removeExclusion(entry: ExcludedPathEntry) {
        store.removeExclusion(path: URL(fileURLWithPath: entry.path))
        excludedPathSizes.removeValue(forKey: entry.path)
    }

    // MARK: - Shared settings layout
    //
    // Settings is four groups. Each is a small label above a card, and inside the
    // card one row per setting: title (with an info button when there is more to
    // say), at most one short caption or status line, control on the trailing edge.

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, AppStyle.Spacing.xxSmall)
                .accessibilityAddTraits(.isHeader)

            settingsSectionCard(content: content)
        }
    }

    /// Title plus supporting copy, the left half of every settings row.
    private func settingsRowLabel(
        title: String,
        caption: String?,
        info: String? = nil,
        warning: String? = nil,
        status: SettingsRowStatus? = nil,
        animatesCaptionChanges: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(title))
                if let info {
                    SettingsInfoButton(text: info, title: title)
                }
            }

            if let caption {
                Text(LocalizedStringKey(caption))
                    .settingsCaption()
                    .contentTransition(animatesCaptionChanges ? scheduleTextTransition : .identity)
                    .animation(animatesCaptionChanges ? scheduleTextAnimation : nil, value: caption)
            }

            if let status {
                SettingsStatusLine(status: status)
            }

            if let warning {
                Text(LocalizedStringKey(warning))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private func settingsToggleRow(
        title: String,
        caption: String? = nil,
        info: String? = nil,
        warning: String? = nil,
        status: SettingsRowStatus? = nil,
        captionAnimatesTextChanges: Bool = false,
        isToggleDisabled: Bool = false,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingsRowLabel(
                title: title,
                caption: caption,
                info: info,
                warning: warning,
                status: status,
                animatesCaptionChanges: captionAnimatesTextChanges
            )

            // Only the switch is disabled, so the info button can still explain why.
            Toggle(LocalizedStringKey(title), isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(AppColors.statusSafeText)
                .disabled(isToggleDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func settingsControlRow<Control: View>(
        title: String,
        caption: String? = nil,
        info: String? = nil,
        animatesCaptionChanges: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingsRowLabel(title: title, caption: caption, info: info, animatesCaptionChanges: animatesCaptionChanges)

            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func settingsPickerRow<Option: Hashable>(
        title: String,
        caption: String? = nil,
        info: String? = nil,
        selection: Binding<Option>,
        options: [Option],
        optionLabel: @escaping (Option) -> String
    ) -> some View {
        settingsControlRow(title: title, caption: caption, info: info) {
            SettingsMenuPicker(
                selection: selection,
                options: options,
                optionLabel: optionLabel,
                accessibilityTitle: title
            )
        }
    }

    /// A row that opens a sheet: title, a short summary, and a chevron.
    private func settingsLinkRow(
        title: String,
        value: String,
        valueIsFigure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
                Text(LocalizedStringKey(title))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(value)
                    .font(valueIsFigure ? scheduleStatusSecondaryFont.numbers : scheduleStatusSecondaryFont)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
    }

    private var settingsHorizontalContentInset: CGFloat { AppDetailPageLayout.horizontalInset }

    private var contentTopPadding: CGFloat {
        if usesExternalScrollContainer {
            // macOS 26 reserves this clearance inside the scroll-edge bar instead, so that
            // rows scrolling up dissolve below the title rather than at its baseline.
            if #available(macOS 26.0, *) { return 0 }
            return AppDetailPageLayout.clearanceBelowHeader
        }
        return showsPageHeader ? AppDetailPageLayout.topContentInset : AppStyle.Spacing.medium
    }

    private var contentBottomPadding: CGFloat {
        if usesExternalScrollContainer {
            return AppStyle.Spacing.large
        }
        return AppDetailPageLayout.verticalPadding
    }

    private var currentDevToolsStalenessOption: DevToolsStalenessOption {
        DevToolsStalenessOption(rawValue: devToolsStalenessThresholdRaw) ?? .defaultOption
    }

    private var devToolsStalenessSelectionBinding: Binding<DevToolsStalenessOption> {
        Binding(
            get: {
                DevToolsStalenessOption(rawValue: devToolsStalenessThresholdRaw) ?? .defaultOption
            },
            set: { newValue in
                devToolsStalenessThresholdRaw = newValue.rawValue
            }
        )
    }

    private var settingsSectionDivider: some View {
        InsetCardDivider()
    }

    private func settingsSectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
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

    private var scheduleSummary: String {
        String(localized: """
        \(prefs.frequency.everyPhrase(customAmount: prefs.customIntervalAmount, customUnit: prefs.customIntervalUnit)), we will quietly clean the same safe items as the \
        Clean Safe Items button - safe caches and stale developer artifacts. Your actual work is \
        never deleted.
        """)
    }

    private var nextScheduledCleanDate: Date {
        ScheduledCleaningRegistrar.shared.nextCleanDate()
    }

    private var scheduleStatusPrimaryFont: Font {
        AppStyle.Typography.body
    }

    private var scheduleStatusSecondaryFont: Font {
        AppStyle.Typography.callout
    }

    private var scheduleTextTransition: ContentTransition {
        reduceMotion ? .identity : .numericText()
    }

    private var scheduleTextAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.45)
    }

    private var scheduleLayoutAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
    }

    private var autoCleanEnabledBinding: Binding<Bool> {
        Binding(
            get: { prefs.isEnabled },
            set: { newVal in
                Task { await prefs.setEnabled(newVal, animation: scheduleLayoutAnimation) }
            }
        )
    }

    /// Selecting "Custom" never writes `.custom` directly — it opens the interval
    /// popup, and `.custom` is only committed when the user saves there. Re-selecting
    /// Custom re-opens the popup with the saved values, doubling as the edit path.
    private var frequencySelectionBinding: Binding<ScheduledCleaningFrequency> {
        Binding(
            get: { prefs.frequency },
            set: { newVal in
                if newVal == .custom {
                    showCustomIntervalSheet = true
                } else {
                    prefs.frequency = newVal
                }
            }
        )
    }

    /// Two complementary descriptions of the next-clean date: a prominent line and a
    /// faded supporting line. When the date is a named day (Today/Tomorrow/Yesterday)
    /// the friendly word leads and the exact date supports it; otherwise the exact
    /// date leads and the relative distance supports it. This guarantees the two
    /// lines never read the same, so a clean due today no longer shows "Today" twice.
    private func nextCleanDisplay(referenceDate: Date) -> (primary: String, secondary: String?) {
        let date = nextScheduledCleanDate
        let absolute = formattedDate(date)
        let relative = relativeDateText(for: date, referenceDate: referenceDate)

        if isNamedRelativeDay(date, referenceDate: referenceDate) {
            return (primary: relative, secondary: absolute)
        }
        return (primary: absolute, secondary: relative)
    }

    /// Whether `relativeDateText` would render `date` as Today, Tomorrow, or
    /// Yesterday relative to `referenceDate`. Mirrors that helper's calendar logic.
    private func isNamedRelativeDay(_ date: Date, referenceDate: Date) -> Bool {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: referenceDate) { return true }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: tomorrow) { return true }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: yesterday) { return true }
        return false
    }

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

struct SettingsMenuPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let optionLabel: (Option) -> String
    let accessibilityTitle: String
    var fillsWidth = false

    private var labelMinWidth: CGFloat { fillsWidth ? 0 : 120 }

    var body: some View {
        AppDropdown(
            options: options,
            selection: selection,
            optionLabel: optionLabel,
            onSelect: { selection = $0 }
        ) {
            HStack(spacing: 8) {
                Text(optionLabel(selection))
                    .lineLimit(1)

                Spacer(minLength: fillsWidth ? 8 : 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(minWidth: labelMinWidth)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(SettingsPickerButtonStyle())
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(optionLabel(selection))
    }
}

private struct SettingsPickerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppStyle.Typography.body)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: AppStyle.Control.height)
            .background(
                configuration.isPressed ? AppColors.fillSecondary : AppColors.surfaceRaised,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private enum ScheduleStatusHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension ScheduledCleaningFrequency {
    func everyPhrase(customAmount: Int, customUnit: CustomCleaningIntervalUnit) -> String {
        switch self {
        case .weekly:
            return String(localized: "Every week")
        case .monthly:
            return String(localized: "Every month")
        case .quarterly:
            return String(localized: "Every 3 months")
        case .custom:
            return customUnit.everyPhrase(amount: customAmount)
        }
    }

}

/// Which way a login item change failed, so the warning names the right action.
private enum LoginItemFailure {
    case enable
    case disable

    var message: String {
        switch self {
        case .enable: String(localized: "Couldn't turn this on. Check Login Items in System Settings.")
        case .disable: String(localized: "Couldn't turn this off. Check Login Items in System Settings.")
        }
    }
}

private struct AppearanceOptionButton: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                thumbnail
                    .overlay {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                            .strokeBorder(AppColors.borderStrong, lineWidth: 0.5)
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                                .inset(by: -3)
                                .strokeBorder(AppColors.textPrimary, lineWidth: 2)
                        }
                    }

                Text(mode.displayName)
                    .font(AppStyle.Typography.metadata.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel("\(mode.displayName) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var thumbnail: some View {
        Image(mode.thumbnailAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
    }
}


/// A row's one status line: what state the feature is in, and the one fix when
/// something is wrong.
struct SettingsRowStatus: Equatable {
    let text: String
    let tint: Color
    var showsProgress = false
    var actionTitle: String?
    var isActionDisabled = false
    var action: (() -> Void)?

    static func == (lhs: SettingsRowStatus, rhs: SettingsRowStatus) -> Bool {
        lhs.text == rhs.text && lhs.tint == rhs.tint && lhs.showsProgress == rhs.showsProgress
            && lhs.actionTitle == rhs.actionTitle && lhs.isActionDisabled == rhs.isActionDisabled
    }
}

struct SettingsStatusLine: View {
    let status: SettingsRowStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if status.showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(status.text))
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(status.tint)
                .fixedSize(horizontal: false, vertical: true)

            if let title = status.actionTitle, let action = status.action {
                Button(LocalizedStringKey(title), action: action)
                    .buttonStyle(.purge(.secondary, size: .small))
                    .disabled(status.isActionDisabled)
            }
        }
    }
}

/// The small (i) beside a setting's title. The full explanation lives here, so
/// the row itself stays one line.
private struct SettingsInfoButton: View {
    let text: String
    let title: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "More about \(title)"))
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            SettingsInfoPopover(text: text)
        }
    }
}

struct SettingsInfoPopover: View {
    let text: String

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(AppStyle.Typography.callout)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300, alignment: .leading)
            .padding(AppStyle.Spacing.medium)
    }
}
