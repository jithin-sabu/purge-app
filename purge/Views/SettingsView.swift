import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PurgeStore
    @ObservedObject private var prefs = ScheduledCleaningPreferenceStore.shared
    @ObservedObject private var history = CleanupHistoryStore.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    // @AppStorage("telemetry.lastSentDate") private var telemetryLastSentTimestamp = 0.0

    @State private var easterEggTapTimes: [Date] = []
    @State private var showEasterEgg = false
    @State private var easterEggSessionMadeByTweak = false
    // @State private var showTelemetryPreviewSheet = false
    // @State private var isSendingTelemetry = false
    // @State private var telemetryError: String?
    // @State private var telemetryToast: String?
    // @State private var telemetryToastID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(AppStyle.Typography.pageTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                cleaningScheduleSection

                // Divider()
                // telemetrySection
            }
            .frame(maxWidth: settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: AppStyle.Spacing.large)

            settingsFooterSection
                .frame(maxWidth: settingsContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, settingsHorizontalContentInset)
        .padding(.top, AppDetailPageLayout.topContentInset)
        .padding(.bottom, AppDetailPageLayout.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppStyle.canvas)
        // .sheet(isPresented: $showTelemetryPreviewSheet) {
        //     TelemetryPreviewSheet(
        //         payload: TelemetryService.makePayload(from: store),
        //         isSending: isSendingTelemetry,
        //         isSendDisabled: isTelemetrySendDisabled,
        //         onCancel: { showTelemetryPreviewSheet = false },
        //         onSend: sendTelemetryReport
        //     )
        // }
        .overlay {
            if showEasterEgg {
                SettingsEasterEggOverlay(onDismiss: dismissEasterEgg)
                    .transition(.opacity)
            }
        }
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

    private var cleaningScheduleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center) {
                        Text("Cleaning Schedule")
                            .font(.headline)

                        Spacer(minLength: 12)

                        Toggle("Run automatic cleaning", isOn: Binding(
                            get: { prefs.isEnabled },
                            set: { newVal in
                                Task { await prefs.setEnabled(newVal) }
                            }
                        ))
                        .toggleStyle(.switch)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cleaning Schedule")
                            .font(.headline)

                        Toggle("Run automatic cleaning", isOn: Binding(
                            get: { prefs.isEnabled },
                            set: { newVal in
                                Task { await prefs.setEnabled(newVal) }
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(scheduleSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                settingPickerRow(title: "How often") {
                    Picker("How often", selection: $prefs.frequency) {
                        ForEach(ScheduledCleaningFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                }

                settingPickerRow(title: "Untouched for") {
                    Picker("Untouched for", selection: $prefs.unusedDays) {
                        ForEach(ScheduledCleaningUnusedDaysOption.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .disabled(!prefs.isEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Next scheduled clean: \(formattedDate(nextScheduledCleanDate))")

                if let latestScheduledClean {
                    Text(
                        "Last clean: \(formattedDate(latestScheduledClean.date)) · " +
                            "\(formatBytes(latestScheduledClean.totalFreedBytes)) freed"
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
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

    private var aboutMadeByAttribution: String {
        easterEggSessionMadeByTweak
            ? "Made by Jithin (who definitely did not spend 10 minutes on that)"
            : "Made by Jithin"
    }

    private var settingsFooterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: registerAboutEasterEggTap)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Purge")
                        .fontWeight(.semibold)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: registerAboutEasterEggTap)
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Replay Onboarding") {
                hasCompletedOnboarding = false
            }
            .controlSize(.small)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(aboutMadeByAttribution)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Link("Send Feedback", destination: feedbackURL)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(aboutMadeByAttribution)
                    Link("Send Feedback", destination: feedbackURL)
                }
            }
            .font(.subheadline)
        }
    }

    private func settingPickerRow<PickerContent: View>(
        title: String,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                picker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .foregroundStyle(.secondary)

                picker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func registerAboutEasterEggTap() {
        let now = Date()
        if let last = easterEggTapTimes.last, now.timeIntervalSince(last) > 2 {
            easterEggTapTimes = [now]
        } else {
            easterEggTapTimes.append(now)
        }
        guard easterEggTapTimes.count >= 5 else { return }
        easterEggTapTimes.removeAll()
        withAnimation(.easeOut(duration: 0.25)) {
            showEasterEgg = true
        }
    }

    private func dismissEasterEgg() {
        withAnimation(.easeOut(duration: 0.2)) {
            showEasterEgg = false
        }
        easterEggSessionMadeByTweak = true
    }

    /// Caps line length on wide windows; layout still shrinks with a narrow split-view column.
    private var settingsContentMaxWidth: CGFloat { 560 }

    private var settingsHorizontalContentInset: CGFloat { AppDetailPageLayout.horizontalInset }

    private var scheduleSummary: String {
        """
        Every \(prefs.frequency.summaryPhrase), we will quietly remove safe files and stale developer \
        artifacts untouched for \(prefs.unusedDays.summaryDurationPhrase). \
        Your actual work is never deleted.
        """
    }

    private var nextScheduledCleanDate: Date {
        let today = Date()
        return Calendar.current.date(byAdding: prefs.frequency.calendarComponent, to: today) ?? today
    }

    private var latestScheduledClean: CleanupHistoryEntry? {
        history.archive.entries.first { $0.trigger == .scheduled }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)) where build != version:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        case let (_, .some(build)):
            return build
        default:
            return "1.0.0"
        }
    }

    private var feedbackURL: URL {
        URL(string: "mailto:design@jithinsabu.com?subject=Purge%20Feedback")!
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

private struct SettingsEasterEggOverlay: View {
    let onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)

            VStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Oh, you found this.")
                        .font(.title2)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Cool.")
                        .foregroundStyle(.secondary)

                    Text("No seriously, cool.")
                        .foregroundStyle(.secondary)

                    Text("We spent like 10 minutes on it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 14)

                HStack {
                    Spacer()
                    Button("Ok fine thanks", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            .padding(20)
            .frame(width: 320, height: 220)
            .fixedSize(horizontal: true, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .environment(\.colorScheme, .dark)
            .scaleEffect(appeared ? 1.0 : 0.95)
            .opacity(appeared ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                appeared = true
            }
        }
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

    var calendarComponent: DateComponents {
        switch self {
        case .weekly:
            return DateComponents(day: 7)
        case .monthly:
            return DateComponents(month: 1)
        case .quarterly:
            return DateComponents(month: 3)
        }
    }
}
