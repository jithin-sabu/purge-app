import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PurgeStore
    @ObservedObject private var prefs = ScheduledCleaningPreferenceStore.shared
    @ObservedObject private var history = CleanupHistoryStore.shared
    @ObservedObject private var aiUsage = AIUsageStore.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("settings.aiIdentification.debugMode") private var aiIdentificationDebugMode = false
    @AppStorage("telemetry.lastSentDate") private var telemetryLastSentTimestamp = 0.0
    @State private var apiKeyText = ""
    @State private var apiKeyError: String?
    @State private var hasStoredAPIKey = false
    @State private var isEditingAPIKey = false
    @State private var storedAPIKeyLength = 0
    @State private var showClearAPIKeyAlert = false
    @State private var debugTitleTapTimes: [Date] = []
    @State private var apiKeyVerification: APIKeyVerificationState = .idle
    @FocusState private var apiKeyFieldFocused: Bool

    @State private var showResetAICacheAlert = false
    @State private var showClearOverridesAlert = false
    @State private var showResetEverythingAlert = false
    @State private var categorizationToast: String?
    @State private var categorizationToastID = UUID()
    @State private var easterEggTapTimes: [Date] = []
    @State private var showEasterEgg = false
    @State private var easterEggSessionMadeByTweak = false
    @State private var showTelemetryPreviewSheet = false
    @State private var isSendingTelemetry = false
    @State private var telemetryError: String?
    @State private var telemetryToast: String?
    @State private var telemetryToastID = UUID()

    private enum APIKeyVerificationState: Equatable {
        case idle
        case verifying
        case verified
        case failed(String)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 28) {
                    cleaningScheduleSection

                    Divider()

                    aiIdentificationSection
                }
                .padding(.horizontal, settingsHorizontalContentInset)

                Divider()

                categorizationSection

                Divider()

                VStack(alignment: .leading, spacing: 28) {
                    telemetrySection

                    Divider()

                    aboutSection
                }
                .padding(.horizontal, settingsHorizontalContentInset)
            }
            .frame(maxWidth: settingsContentMaxWidth, alignment: .leading)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .onAppear {
            refreshAPIKeyState()
        }
        .alert("Remove your API key?", isPresented: $showClearAPIKeyAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                clearAPIKey()
            }
        } message: {
            Text(
                """
                Purge will no longer be able to identify unknown cache folders automatically. You can add it back any \
                time in Settings.
                """
            )
        }
        .alert("Reset AI categorizations?", isPresented: $showResetAICacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                store.clearAICacheAndReapply()
                showCategorizationToast("Saved types cleared. Re-scan to re-identify folders.")
            }
        } message: {
            Text(
                """
                All folder identifications will be cleared. Purge will re-identify everything on your next scan using \
                AI. This may take a moment.
                """
            )
        }
        .alert("Clear your manual categories?", isPresented: $showClearOverridesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                store.clearAllUserOverridesAndReapply()
                showCategorizationToast("Manual categories cleared.")
            }
        } message: {
            Text(
                """
                Any folders you manually categorized will go back to automatic categorization.
                """
            )
        }
        .alert("Reset all categorizations?", isPresented: $showResetEverythingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                store.resetEverythingAndReapply()
                showCategorizationToast("Everything reset. Re-scan to start fresh.")
            }
        } message: {
            Text(
                """
                This clears both saved automatic categorizations and any manual categories you have set. Everything will \
                be re-identified from scratch on your next scan.
                """
            )
        }
        .sheet(isPresented: $showTelemetryPreviewSheet) {
            TelemetryPreviewSheet(
                payload: TelemetryService.makePayload(from: store),
                isSending: isSendingTelemetry,
                isSendDisabled: isTelemetrySendDisabled,
                onCancel: { showTelemetryPreviewSheet = false },
                onSend: sendTelemetryReport
            )
        }
        .overlay {
            if showEasterEgg {
                SettingsEasterEggOverlay(onDismiss: dismissEasterEgg)
                    .transition(.opacity)
            }
        }
    }

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
                            "Cache folder names and sizes",
                            "How each folder was categorized",
                            "Your macOS version and app version"
                        ]
                    )

                    telemetryBulletList(
                        title: "What never gets sent:",
                        bullets: [
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
                            "Cache folder names and sizes",
                            "How each folder was categorized",
                            "Your macOS version and app version"
                        ]
                    )

                    telemetryBulletList(
                        title: "What never gets sent:",
                        bullets: [
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
                .tint(Color.accentColor)
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

    private var categorizationSection: some View {
        let aiCacheCount = AICacheStore.count()
        let manualCategoryCount = UserOverridesStore.count()

        return VStack(alignment: .leading, spacing: 10) {
            Text("Categorization")
                .font(.headline)
                .padding(.horizontal, settingsHorizontalContentInset)

            Form {
                Section {
                    categorizationFormRow(
                        title: "AI Categorizations",
                        detail: """
                        Clears saved folder types so everything gets re-identified on your next scan. \
                        Use this if folders seem miscategorized.
                        """,
                        status: aiCacheCount == 0
                            ? "No saved categorizations"
                            : aiCategorizationMetadataLine(count: aiCacheCount),
                        actionTitle: "Reset",
                        isActionEnabled: aiCacheCount > 0,
                        isDestructive: false,
                        action: { showResetAICacheAlert = true }
                    )

                    categorizationFormRow(
                        title: "Manual Categories",
                        detail: """
                        Removes categories you set yourself. Items will go back to automatic \
                        categorization.
                        """,
                        status: manualCategoryCount == 0
                            ? "No manual categories set"
                            : "\(manualCategoryCount) entries",
                        actionTitle: "Clear",
                        isActionEnabled: manualCategoryCount > 0,
                        isDestructive: false,
                        action: { showClearOverridesAlert = true }
                    )
                }

                Section {
                    categorizationFormRow(
                        title: "Reset everything",
                        detail: """
                        Clears both saved automatic categorizations and any manual categories. Everything will \
                        be re-identified from scratch on your next scan.
                        """,
                        status: nil,
                        actionTitle: "Reset Everything…",
                        isActionEnabled: true,
                        isDestructive: true,
                        action: { showResetEverythingAlert = true }
                    )
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .modifier(CategorizationFormFullWidthMarginsModifier())

            if let categorizationToast {
                Text(categorizationToast)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .id(categorizationToastID)
                    .transition(.opacity)
                    .padding(.top, 4)
                    .padding(.horizontal, settingsHorizontalContentInset)
            }
        }
    }

    private func categorizationFormRow(
        title: String,
        detail: String,
        status: String?,
        actionTitle: String,
        isActionEnabled: Bool,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                categorizationRowTextColumn(title: title, detail: detail, status: status)
                categorizationRowActionButton(
                    title: actionTitle,
                    isDestructive: isDestructive,
                    isEnabled: isActionEnabled,
                    action: action
                )
            }
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 12) {
                categorizationRowTextColumn(title: title, detail: detail, status: status)
                HStack {
                    Spacer(minLength: 0)
                    categorizationRowActionButton(
                        title: actionTitle,
                        isDestructive: isDestructive,
                        isEnabled: isActionEnabled,
                        action: action
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func categorizationRowTextColumn(title: String, detail: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func categorizationRowActionButton(
        title: String,
        isDestructive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isDestructive {
            Button(title, role: .destructive, action: action)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!isEnabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
    }

    private func aiCategorizationMetadataLine(count: Int) -> String {
        let updated = categorizationRelativeUpdatedPhrase(for: AICacheStore.lastUpdated())
        return "\(count) entries · Last updated \(updated)"
    }

    private func categorizationRelativeUpdatedPhrase(for date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func showCategorizationToast(_ message: String) {
        categorizationToastID = UUID()
        withAnimation { categorizationToast = message }
        let toastID = categorizationToastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard toastID == categorizationToastID else { return }
            withAnimation { categorizationToast = nil }
        }
    }

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

    private var aboutMadeByAttribution: String {
        easterEggSessionMadeByTweak
            ? "Made by Jithin (who definitely did not spend 10 minutes on that)"
            : "Made by Jithin"
    }

    private var aboutSection: some View {
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

    private var aiIdentificationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Identification")
                .font(.headline)
                .contentShape(Rectangle())
                .onTapGesture(perform: registerDebugTitleTap)

            Text(
                """
                Purge uses AI to explain unknown cache folders in plain \
                English. Results are saved permanently so each folder is \
                only ever looked up once.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Typical scan: 3 to 10 AI calls")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("API Key")
                            .foregroundStyle(.secondary)
                            .frame(width: apiKeyLabelColumnWidth, alignment: .leading)

                        apiKeyField

                        if hasStoredAPIKey {
                            keySavedBadge
                        }

                        apiKeyActionButtons
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("API Key")
                            .foregroundStyle(.secondary)

                        apiKeyField

                        HStack(spacing: 10) {
                            if hasStoredAPIKey {
                                keySavedBadge
                            }

                            apiKeyActionButtons

                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Your key is stored securely in the macOS Keychain and never shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if aiIdentificationDebugMode {
                aiDebugStatusPanel
            }

            HStack {
                Spacer()
                Link(destination: openRouterKeysURL) {
                    HStack(spacing: 3) {
                        Text("Get Free API Key")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .font(.subheadline)
            }
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

    @ViewBuilder
    private var apiKeyField: some View {
        if hasStoredAPIKey && !isEditingAPIKey {
            maskedAPIKeyField
        } else {
            apiKeySecureField
        }
    }

    private var apiKeySecureField: some View {
        SecureField(hasStoredAPIKey ? "Paste a new API key here" : "Paste your API key here", text: $apiKeyText)
            .textFieldStyle(.roundedBorder)
            .focused($apiKeyFieldFocused)
            .onSubmit(validateAndSaveAPIKey)
            .onChange(of: apiKeyFieldFocused) { isFocused in
                if isFocused {
                    apiKeyError = nil
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var maskedAPIKeyField: some View {
        Text(maskedAPIKeyText)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .accessibilityLabel("Saved API key")
            .accessibilityValue("Hidden")
    }

    private var apiKeyActionButtons: some View {
        HStack(spacing: 8) {
            if hasStoredAPIKey && !isEditingAPIKey {
                Button("Edit") {
                    beginEditingAPIKey()
                }
            } else {
                Button("Save") {
                    validateAndSaveAPIKey()
                }
                .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredAPIKey {
                    Button("Cancel") {
                        cancelEditingAPIKey()
                    }
                }
            }

            Button("Clear") {
                showClearAPIKeyAlert = true
            }
            .disabled(!hasStoredAPIKey)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var keySavedBadge: some View {
        switch apiKeyVerification {
        case .verifying:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Label("Key saved", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
        case .verified:
            Text("✓ Key saved and verified")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("✗ Key saved but AI test failed. Check your key.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .idle:
            Label("Key saved", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
    }

    private var aiDebugStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Status")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            aiDebugStatusRow(label: "Last call", value: lastCallStatusDebugText, valueColor: lastCallStatusColor)

            aiDebugStatusRow(
                label: "Last folder",
                value: aiUsage.lastCallFolderName ?? "—",
                valueColor: .primary
            )

            if aiUsage.lastCallStatus == .failed, let err = aiUsage.lastCallError, !err.isEmpty {
                aiDebugStatusRow(label: "Last error", value: err, valueColor: .red)
            }

            aiDebugStatusRow(
                label: "Time",
                value: relativeTimePhrase(for: aiUsage.lastCallDate),
                valueColor: .primary
            )

            if aiUsage.lastCallStatus == .failed {
                aiDebugFailureBanner
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var lastCallStatusDebugText: String {
        switch aiUsage.lastCallStatus {
        case .never:
            return "Never run"
        case .success:
            return "✓ Success"
        case .failed:
            return "✗ Failed"
        }
    }

    private var lastCallStatusColor: Color {
        switch aiUsage.lastCallStatus {
        case .never:
            return .secondary
        case .success:
            return .green
        case .failed:
            return .red
        }
    }

    private func aiDebugStatusRow(label: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            if label == "Last call" {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(valueColor)
            } else {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var aiDebugFailureBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(
                """
                ⚠ AI identification is not working.
                Check your API key in Settings or try again.
                """
            )
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry") {
                runAITestCall()
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func registerDebugTitleTap() {
        let now = Date()
        debugTitleTapTimes.append(now)
        debugTitleTapTimes.removeAll { now.timeIntervalSince($0) > 1.5 }
        guard debugTitleTapTimes.count >= 7 else { return }
        debugTitleTapTimes.removeAll()
        aiIdentificationDebugMode = !aiIdentificationDebugMode
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

    private func relativeTimePhrase(for date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func runAITestCall() {
        Task {
            do {
                _ = try await OpenRouterExplanationClient.fetchExplanation(folderName: AIUsageStore.testFolderName)
            } catch {
                // Status is recorded by OpenRouterExplanationClient; swallow for fire-and-forget retry.
            }
        }
    }

    private func runAITestAfterKeySave() {
        apiKeyVerification = .verifying
        Task {
            do {
                _ = try await OpenRouterExplanationClient.fetchExplanation(folderName: AIUsageStore.testFolderName)
                await MainActor.run {
                    apiKeyVerification = .verified
                }
            } catch {
                let message = OpenRouterExplanationClient.friendlyMessage(for: error)
                await MainActor.run {
                    apiKeyVerification = .failed(message)
                }
            }
        }
    }

    private var apiKeyLabelColumnWidth: CGFloat { 82 }

    /// Caps line length on wide windows; layout still shrinks with a narrow split-view column.
    private var settingsContentMaxWidth: CGFloat { 560 }

    private var settingsHorizontalContentInset: CGFloat { 24 }

    private var scheduleSummary: String {
        """
        Every \(prefs.frequency.summaryPhrase), we will quietly remove safe files \
        that have not been touched in over \(prefs.unusedDays.rawValue) days. \
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

    private var openRouterKeysURL: URL {
        URL(string: "https://openrouter.ai/settings/keys")!
    }

    private var maskedAPIKeyText: String {
        String(repeating: "•", count: max(storedAPIKeyLength, 1))
    }

    private func refreshAPIKeyState() {
        let storedAPIKey = KeychainStore.read(key: "openrouter-api-key")
        hasStoredAPIKey = storedAPIKey != nil
        storedAPIKeyLength = storedAPIKey?.count ?? 0
        apiKeyText = hasStoredAPIKey ? maskedAPIKeyText : ""
        apiKeyError = nil
        isEditingAPIKey = false
        apiKeyVerification = .idle
    }

    private func validateAndSaveAPIKey() {
        let trimmed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != maskedAPIKeyText else { return }

        guard OpenRouterExplanationClient.looksLikeAPIKey(trimmed) else {
            apiKeyError = "This doesn't look like a valid OpenRouter API key"
            return
        }

        do {
            try KeychainStore.save(key: "openrouter-api-key", value: trimmed)
            hasStoredAPIKey = true
            storedAPIKeyLength = trimmed.count
            apiKeyText = maskedAPIKeyText
            apiKeyError = nil
            isEditingAPIKey = false
            apiKeyFieldFocused = false
            runAITestAfterKeySave()

            NotificationCenter.default.post(name: .apiKeyAdded, object: nil)
            Task {
                await store.reidentifyUnknownItems()
            }
        } catch {
            apiKeyError = "We couldn't save this API key. Please try again."
        }
    }

    private func beginEditingAPIKey() {
        isEditingAPIKey = true
        apiKeyText = ""
        apiKeyError = nil
        apiKeyVerification = .idle
        apiKeyFieldFocused = true
    }

    private func cancelEditingAPIKey() {
        isEditingAPIKey = false
        apiKeyText = hasStoredAPIKey ? maskedAPIKeyText : ""
        apiKeyError = nil
        apiKeyFieldFocused = false
        apiKeyVerification = .idle
    }

    private func clearAPIKey() {
        do {
            try KeychainStore.delete(key: "openrouter-api-key")
            hasStoredAPIKey = false
            storedAPIKeyLength = 0
            isEditingAPIKey = false
            apiKeyText = ""
            apiKeyError = nil
            apiKeyFieldFocused = false
            apiKeyVerification = .idle
        } catch {
            apiKeyError = "We couldn't remove this API key. Please try again."
        }
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

    private static let telemetryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

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
                    Text("All cache folders (\(payload.totalCount))")
                        .font(.subheadline.weight(.semibold))

                    Text(displayList(payload.allFolderNames))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Unidentified folders (\(payload.unknownCount))")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    Text(displayList(payload.unknownFolderNames))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                No personal data. No file contents.
                Just these folder names.
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
                        Text("Send anyway")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(isSendDisabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func displayList(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}

/// Drops grouped `Form` horizontal scroll gutters when the API exists so rows align with the pane edges.
private struct CategorizationFormFullWidthMarginsModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentMargins(.horizontal, 0, for: .scrollContent)
        } else {
            content
        }
    }
}

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
