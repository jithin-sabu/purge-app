import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var prefs = ScheduledCleaningPreferenceStore.shared
    @AppStorage(DevToolsStalenessOption.userDefaultsKey)
    private var devToolsStalenessThresholdRaw = DevToolsStalenessOption.defaultOption.rawValue
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    var showsPageHeader = true
    /// When true, the parent owns scrolling and the macOS 26 progressive scroll-edge blur.
    var usesExternalScrollContainer = false
    // @AppStorage("telemetry.lastSentDate") private var telemetryLastSentTimestamp = 0.0

    // @State private var showTelemetryPreviewSheet = false
    // @State private var isSendingTelemetry = false
    // @State private var telemetryError: String?
    // @State private var telemetryToast: String?
    // @State private var telemetryToastID = UUID()

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
                }

                // Divider()
                // telemetrySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, settingsHorizontalContentInset)
        .padding(.top, contentTopPadding)
        .padding(.bottom, AppDetailPageLayout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: usesExternalScrollContainer ? nil : .infinity, alignment: .topLeading)
        .background(AppStyle.canvas)
        .onChange(of: devToolsStalenessThresholdRaw) { _ in
            Task { await store.scanAll() }
        }
        // .sheet(isPresented: $showTelemetryPreviewSheet) {
        //     TelemetryPreviewSheet(
        //         payload: TelemetryService.makePayload(from: store),
        //         isSending: isSendingTelemetry,
        //         isSendDisabled: isTelemetrySendDisabled,
        //         onCancel: { showTelemetryPreviewSheet = false },
        //         onSend: sendTelemetryReport
        //     )
        // }
    }

    /*
    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Help Improve Purge")
                .font(.headline)

            Text(
                """
                Send anonymous scan data to help us identify cache folders more accurately for everyone.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    telemetryBulletList(
                        title: "What gets sent:",
                        bullets: [
                            "Cache folders marked Safe to Clean or Check First",
                            "Your macOS version and app version"
                        ]
                    )

                    telemetryBulletList(
                        title: "What never gets sent:",
                        bullets: [
                            "Folders marked Do Not Delete or Not Sure",
                            "File contents",
                            "Personal data",
                            "Your name or any identifier"
                        ]
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    telemetryBulletList(
                        title: "What gets sent:",
                        bullets: [
                            "Cache folders marked Safe to Clean or Check First",
                            "Your macOS version and app version"
                        ]
                    )

                    telemetryBulletList(
                        title: "What never gets sent:",
                        bullets: [
                            "Folders marked Do Not Delete or Not Sure",
                            "File contents",
                            "Personal data",
                            "Your name or any identifier"
                        ]
                    )
                }
            }

            Text("Last sent: \(telemetryLastSentText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 10) {
                Button("Preview Data") {
                    telemetryError = nil
                    showTelemetryPreviewSheet = true
                }
                .buttonStyle(.bordered)
                .disabled(isSendingTelemetry)

                Button(action: sendTelemetryReport) {
                    HStack(spacing: 6) {
                        if isSendingTelemetry {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(telemetrySendButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppStyle.accent)
                .disabled(isTelemetrySendDisabled)
            }

            if let telemetryError {
                Text(telemetryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            if let telemetryToast {
                Text(telemetryToast)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .id(telemetryToastID)
                    .transition(.opacity)
            }
        }
    }

    private func telemetryBulletList(title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    */

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
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cleaning Schedule")
                        .font(.headline)

                    Toggle("Run automatic cleaning", isOn: autoCleanEnabledBinding)
                        .toggleStyle(.switch)
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

                VStack(spacing: 8) {
                    settingPickerRow(
                        title: "How often",
                        selection: $prefs.frequency,
                        options: ScheduledCleaningFrequency.allCases,
                        optionLabel: \.displayName
                    )

                    settingPickerRow(
                        title: "Untouched for",
                        selection: $prefs.unusedDays,
                        options: ScheduledCleaningUnusedDaysOption.allCases,
                        optionLabel: \.label
                    )
                }
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
            }
        }
    }

    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dev Tools")
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

    /*
    private var telemetryLastSentDate: Date? {
        guard telemetryLastSentTimestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: telemetryLastSentTimestamp)
    }

    private var telemetryLastSentText: String {
        guard let telemetryLastSentDate else { return "Never" }
        return Self.telemetryDateFormatter.string(from: telemetryLastSentDate)
    }

    private var isTelemetryRateLimited: Bool {
        guard let telemetryLastSentDate else { return false }
        return Date().timeIntervalSince(telemetryLastSentDate) < 24 * 60 * 60
    }

    private var isTelemetrySendDisabled: Bool {
        isSendingTelemetry || isTelemetryRateLimited
    }

    private var telemetrySendButtonTitle: String {
        isTelemetryRateLimited ? "Sent today" : "Send Anonymous Report"
    }

    private func sendTelemetryReport() {
        guard !isTelemetrySendDisabled else { return }

        telemetryError = nil
        telemetryToast = nil
        isSendingTelemetry = true

        // Telemetry is opt-in only: this is called exclusively by the explicit Settings buttons.
        Task {
            let submissionDate = Date()
            let payload = TelemetryService.makePayload(from: store, submissionDate: submissionDate)

            do {
                try await TelemetryService.sendTelemetry(payload: payload)
                telemetryLastSentTimestamp = submissionDate.timeIntervalSince1970
                showTelemetryPreviewSheet = false
                showTelemetryToast("Thanks for helping improve Purge 🙌")
            } catch {
                telemetryError = "Could not send. Check your connection and try again."
            }

            isSendingTelemetry = false
        }
    }

    private func showTelemetryToast(_ message: String) {
        telemetryToastID = UUID()
        withAnimation { telemetryToast = message }
        let toastID = telemetryToastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard toastID == telemetryToastID else { return }
            withAnimation { telemetryToast = nil }
        }
    }
    */

    private func settingPickerRow<Option: Hashable>(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        optionLabel: @escaping (Option) -> String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                    .foregroundStyle(AppStyle.formLabel)

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
                    .foregroundStyle(AppStyle.formLabel)

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

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                scheduleStatusLabel("Next clean", showsDueDot: isDueToday)

                Text(primaryNextCleanDateText(referenceDate: referenceDate))
                    .font(scheduleStatusPrimaryFont)
                    .foregroundStyle(.primary)
                    .contentTransition(scheduleTextTransition)
                    .animation(
                        scheduleTextAnimation,
                        value: primaryNextCleanDateText(referenceDate: referenceDate)
                    )

                Text(relativeDateText(for: nextScheduledCleanDate, referenceDate: referenceDate))
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(.tertiary)
                    .contentTransition(scheduleTextTransition)
                    .animation(
                        scheduleTextAnimation,
                        value: relativeDateText(for: nextScheduledCleanDate, referenceDate: referenceDate)
                    )
            }
        }
    }

    private func scheduleStatusLabel(_ title: String, showsDueDot: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(scheduleStatusLabelFont)
                .foregroundStyle(.secondary)

            if showsDueDot {
                Circle()
                    .fill(AppStyle.accent)
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
                .foregroundStyle(AppStyle.accent)
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
                AppStyle.elevated,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppStyle.hairline, lineWidth: 0.5)
            }
    }

    private var scheduleSummary: String {
        """
        Every \(prefs.frequency.summaryPhrase), we will quietly remove safe files and stale developer \
        artifacts untouched for \(prefs.unusedDays.summaryDurationPhrase). \
        Your actual work is never deleted.
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

    private func primaryNextCleanDateText(referenceDate: Date) -> String {
        Calendar.current.isDate(nextScheduledCleanDate, inSameDayAs: referenceDate)
            ? "Today"
            : formattedDate(nextScheduledCleanDate)
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

    /*
    private static let telemetryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    */
}

/*
private struct TelemetryPreviewSheet: View {
    let payload: TelemetryPayload
    let isSending: Bool
    let isSendDisabled: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What will be sent")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cache folders (\(payload.totalCount))")
                        .font(.subheadline.weight(.semibold))

                    Text(previewFolderCategories(payload))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS: \(payload.macOSVersion)")
                        Text("Purge: \(payload.appVersion)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .frame(minHeight: 260)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text(
                """
                Only Safe to Clean and Check First folders are included.
                No personal data, file contents, or full folder paths.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSending)

                Button(action: onSend) {
                    HStack(spacing: 6) {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSending ? "Sending…" : "Send Report")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppStyle.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSendDisabled || isSending)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func previewFolderCategories(_ payload: TelemetryPayload) -> String {
        let rows = payload.folderCategoryRows
        guard !rows.isEmpty else {
            return "No Safe to Clean or Check First folders in the latest scan."
        }
        return rows
            .map { "\($0.folderName) — \($0.categoryLabel)" }
            .joined(separator: "\n")
    }
}
*/

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
                configuration.isPressed ? AppStyle.rowHover : AppStyle.controlFill,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
                    .strokeBorder(AppStyle.hairline, lineWidth: 0.5)
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
                                .strokeBorder(AppStyle.accent, lineWidth: 2)
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
