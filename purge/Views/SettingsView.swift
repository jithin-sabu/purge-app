import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var prefs = ScheduledCleaningPreferenceStore.shared
    @ObservedObject private var registrar = ScheduledCleaningRegistrar.shared
    @ObservedObject private var history = CleanupHistoryStore.shared
    @AppStorage(DevToolsStalenessOption.userDefaultsKey)
    private var devToolsStalenessThresholdRaw = DevToolsStalenessOption.defaultOption.rawValue
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(DeveloperMode.userDefaultsKey)
    private var developerModeEnabled = false
    var showsPageHeader = true
    /// When true, the parent owns scrolling and the macOS 26 progressive scroll-edge blur.
    var usesExternalScrollContainer = false

    @State private var isRunningScheduledCleanNow = false
    @State private var scheduledCleanNowMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: showsPageHeader ? 28 : 0) {
                if showsPageHeader {
                    Text("Settings")
                        .font(AppStyle.Typography.pageTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 18) {
                    appearanceSection
                    cleaningScheduleSection
                    devToolsSection
                    cleaningHistorySection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, settingsHorizontalContentInset)
        .padding(.top, contentTopPadding)
        .padding(.bottom, AppDetailPageLayout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: usesExternalScrollContainer ? nil : .infinity, alignment: .topLeading)
        .background(AppColors.bgBase)
        .onChange(of: devToolsStalenessThresholdRaw) { _ in
            Task { await store.scanAll() }
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

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance")
                .font(.headline)

            settingsSectionCard {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        appearanceDescription

                        Spacer(minLength: 12)

                        appearanceOptions
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        appearanceDescription
                        appearanceOptions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        }
    }

    private var appearanceDescription: some View {
        Text("Choose a light or dark look, or match your system setting.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var appearanceOptions: some View {
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

    private var currentAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var cleaningScheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    Text("Cleaning Schedule")
                        .font(.headline)

                    Spacer(minLength: 12)

                    Toggle("Run automatic cleaning", isOn: autoCleanEnabledBinding)
                        .toggleStyle(.switch)
                        .tint(AppColors.tagSafeText)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cleaning Schedule")
                        .font(.headline)

                    Toggle("Run automatic cleaning", isOn: autoCleanEnabledBinding)
                        .toggleStyle(.switch)
                        .tint(AppColors.tagSafeText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(scheduleSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(scheduleTextTransition)
                        .animation(scheduleTextAnimation, value: scheduleSummary)
                }
                .padding(16)

                settingsSectionDivider

                settingPickerRow(
                    title: "How often",
                    selection: $prefs.frequency,
                    options: ScheduledCleaningFrequency.allCases,
                    optionLabel: \.displayName
                )
                .padding(16)
                .disabled(!prefs.isEnabled)

                settingsSectionDivider

                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    ScheduleStatusAnimatedHeight(
                        reduceMotion: reduceMotion,
                        animation: scheduleLayoutAnimation
                    ) {
                        cleaningScheduleStatusCard(referenceDate: context.date)
                    }
                    .padding(16)
                }

                if prefs.isEnabled && developerModeEnabled {
                    settingsSectionDivider

                    runScheduledCleanNowRow
                        .padding(16)
                }
            }
        }
    }

    /// Verification affordance: runs the real scheduled-clean pipeline now (same
    /// safe rules and staleness thresholds) so users don't have to wait out a full
    /// interval to confirm automatic cleaning works.
    private var runScheduledCleanNowRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                runScheduledCleanNowCopy
                Spacer(minLength: 12)
                runScheduledCleanNowButton
            }

            VStack(alignment: .leading, spacing: 10) {
                runScheduledCleanNowCopy
                runScheduledCleanNowButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runScheduledCleanNowCopy: some View {
        Text("Run a scheduled clean right now to confirm it works. It uses the same safe rules above and counts as this period's clean.")
            .font(scheduleStatusSecondaryFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var runScheduledCleanNowButton: some View {
        Button(action: runScheduledCleanNow) {
            HStack(spacing: 6) {
                if isRunningScheduledCleanNow {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isRunningScheduledCleanNow ? "Cleaning…" : "Run now")
            }
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
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

    private static func scheduledCleanNowMessage(
        for summary: PurgeStore.ScheduledCleaningSummary?
    ) -> String {
        guard let summary else {
            return "Auto-clean is off, so nothing ran. Turn it on and try again."
        }
        if summary.deletedCount == 0 {
            return """
            Nothing matched your safe settings right now — the schedule is working, there just \
            wasn't anything safe to clean yet.
            """
        }
        let noun = summary.deletedCount == 1 ? "item" : "items"
        return "Moved \(summary.deletedCount) \(noun) to Trash, clearing about \(formatBytes(summary.freedBytes))."
    }

    /// Recent cleanup activity, so scheduled cleans are visible in the app instead
    /// of only in a passing notification.
    private var cleaningHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleaning History")
                .font(.headline)

            settingsSectionCard {
                if recentHistoryEntries.isEmpty {
                    Text("No cleans recorded yet. Automatic and manual cleans will show up here.")
                        .font(scheduleStatusSecondaryFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                } else {
                    ForEach(Array(recentHistoryEntries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            settingsSectionDivider
                        }
                        cleaningHistoryRow(entry)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var recentHistoryEntries: [CleanupHistoryEntry] {
        Array(history.archive.entries.prefix(6))
    }

    private func cleaningHistoryRow(_ entry: CleanupHistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.trigger == .scheduled ? "Automatic clean" : "Manual clean")
                    .font(scheduleStatusPrimaryFont)
                    .foregroundStyle(.primary)

                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatBytes(entry.totalFreedBytes))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text("\(entry.deletedItems.count) \(entry.deletedItems.count == 1 ? "item" : "items")")
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Developer Projects")
                .font(.headline)

            settingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingPickerRow(
                        title: "Consider stale after",
                        selection: devToolsStalenessSelectionBinding,
                        options: DevToolsStalenessOption.allCases,
                        optionLabel: \.label
                    )

                    Text(currentDevToolsStalenessOption.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
    }

    private func settingPickerRow<Option: Hashable>(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        optionLabel: @escaping (Option) -> String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer(minLength: 12)

                SettingsMenuPicker(
                    selection: selection,
                    options: options,
                    optionLabel: optionLabel,
                    accessibilityTitle: title
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .foregroundStyle(AppColors.textSecondary)

                SettingsMenuPicker(
                    selection: selection,
                    options: options,
                    optionLabel: optionLabel,
                    accessibilityTitle: title,
                    fillsWidth: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cleaningScheduleStatusCard(referenceDate: Date) -> some View {
        Group {
            if prefs.isEnabled {
                nextCleanStatusRow(referenceDate: referenceDate)
            } else {
                autoCleanDisabledStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(scheduleStatusTransition)
        .animation(scheduleLayoutAnimation, value: prefs.isEnabled)
        .animation(scheduleLayoutAnimation, value: nextScheduledCleanDate.timeIntervalSinceReferenceDate)
    }

    private var autoCleanDisabledStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Auto-clean is off. Turn it on to keep your Mac clean automatically.")
                .font(scheduleStatusSecondaryFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusTextButton("Enable", isDisabled: false, action: enableAutoClean)
        }
    }

    private func nextCleanStatusRow(referenceDate: Date) -> some View {
        let isDueToday = Calendar.current.isDate(nextScheduledCleanDate, inSameDayAs: referenceDate)
        let display = nextCleanDisplay(referenceDate: referenceDate)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    scheduleStatusLabel("Next clean", showsDueDot: isDueToday)

                    Text(display.primary)
                        .font(scheduleStatusPrimaryFont)
                        .foregroundStyle(.primary)
                        .contentTransition(scheduleTextTransition)
                        .animation(scheduleTextAnimation, value: display.primary)

                    if let secondary = display.secondary {
                        Text(secondary)
                            .font(scheduleStatusTertiaryFont)
                            .foregroundStyle(.tertiary)
                            .contentTransition(scheduleTextTransition)
                            .animation(scheduleTextAnimation, value: secondary)
                    }
                }
            }

            lastCleanStatusRow(referenceDate: referenceDate)
        }
    }

    private func lastCleanStatusRow(referenceDate: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                scheduleStatusLabel("Last clean")

                if let outcome = registrar.lastOutcome {
                    Text(lastCleanPrimaryText(for: outcome))
                        .font(scheduleStatusPrimaryFont)
                        .foregroundStyle(.primary)

                    Text(relativeDateText(for: outcome.date, referenceDate: referenceDate))
                        .font(scheduleStatusTertiaryFont)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No scheduled clean has run yet.")
                        .font(scheduleStatusPrimaryFont)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func lastCleanPrimaryText(for outcome: LastScheduledCleanOutcome) -> String {
        guard outcome.deletedCount > 0 else {
            return "Ran on \(formattedDate(outcome.date)) — nothing safe to clean."
        }
        let noun = outcome.deletedCount == 1 ? "item" : "items"
        return "Ran on \(formattedDate(outcome.date)) — cleared \(formatBytes(outcome.freedBytes)) (\(outcome.deletedCount) \(noun))."
    }

    private func scheduleStatusLabel(_ title: String, showsDueDot: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(scheduleStatusLabelFont)
                .foregroundStyle(.secondary)

            if showsDueDot {
                Circle()
                    .fill(AppColors.textPrimary)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
        }
    }

    private func statusTextButton(
        _ title: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(scheduleStatusLinkFont)
                .foregroundStyle(AppColors.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    private var settingsHorizontalContentInset: CGFloat { AppDetailPageLayout.horizontalInset }

    private var contentTopPadding: CGFloat {
        if usesExternalScrollContainer {
            return AppDetailPageLayout.scrollEdgeClearanceBelowHeader
        }
        return showsPageHeader ? AppDetailPageLayout.topContentInset : AppStyle.Spacing.medium
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
                AppColors.bgElevated,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
    }

    private var scheduleSummary: String {
        """
        Every \(prefs.frequency.summaryPhrase), we will quietly clean the same safe items as the \
        Clean Safe Items button - safe caches and stale developer artifacts. Your actual work is \
        never deleted.
        """
    }

    private var nextScheduledCleanDate: Date {
        ScheduledCleaningRegistrar.shared.nextCleanDate()
    }

    private var scheduleStatusLabelFont: Font {
        .system(size: 11, weight: .medium)
    }

    private var scheduleStatusPrimaryFont: Font {
        .system(size: 13, weight: .regular)
    }

    private var scheduleStatusSecondaryFont: Font {
        .system(size: 12, weight: .regular)
    }

    private var scheduleStatusTertiaryFont: Font {
        .system(size: 11, weight: .regular)
    }

    private var scheduleStatusLinkFont: Font {
        .system(size: 11, weight: .medium)
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

    private var scheduleStatusTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .modifier(
            active: ScheduleStatusBlurTransition(blur: 8, opacity: 0),
            identity: ScheduleStatusBlurTransition(blur: 0, opacity: 1)
        )
    }

    private var autoCleanEnabledBinding: Binding<Bool> {
        Binding(
            get: { prefs.isEnabled },
            set: { newVal in
                Task { await prefs.setEnabled(newVal, animation: scheduleLayoutAnimation) }
            }
        )
    }

    private func enableAutoClean() {
        Task { await prefs.setEnabled(true, animation: scheduleLayoutAnimation) }
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

private struct SettingsMenuPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let optionLabel: (Option) -> String
    let accessibilityTitle: String
    var fillsWidth = false

    private var labelMinWidth: CGFloat { fillsWidth ? 0 : 120 }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(optionLabel(option), systemImage: "checkmark")
                    } else {
                        Text(optionLabel(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(optionLabel(selection))
                    .lineLimit(1)

                Spacer(minLength: fillsWidth ? 8 : 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: labelMinWidth)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        }
        .menuStyle(.button)
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
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed ? AppColors.bgElevated : AppColors.bgOverlay,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
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
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .inset(by: -3)
                                .strokeBorder(AppColors.textPrimary, lineWidth: 2)
                        }
                    }

                Text(mode.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ScheduleStatusBlurTransition: ViewModifier {
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
    }
}

private enum ScheduleStatusHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScheduleStatusAnimatedHeight<Content: View>: View {
    let reduceMotion: Bool
    let animation: Animation?
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat?

    var body: some View {
        content()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ScheduleStatusHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(ScheduleStatusHeightKey.self) { newHeight in
                guard newHeight > 0 else { return }
                if height == nil {
                    height = newHeight
                } else if abs((height ?? 0) - newHeight) > 0.5 {
                    if let animation, !reduceMotion {
                        withAnimation(animation) {
                            height = newHeight
                        }
                    } else {
                        height = newHeight
                    }
                }
            }
            .frame(height: height, alignment: .top)
            .clipped()
    }
}

private extension ScheduledCleaningFrequency {
    var summaryPhrase: String {
        switch self {
        case .weekly:
            return "week"
        case .monthly:
            return "month"
        case .quarterly:
            return "3 months"
        }
    }

}
