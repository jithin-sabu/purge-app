import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    let onComplete: () -> Void

    @State private var currentPage = 0
    @State private var apiKeyText = ""
    @State private var apiKeyError: String?
    @State private var hasStoredAPIKey = false
    @FocusState private var apiKeyFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            currentScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 14) {
                navigationButtons
                progressDots
            }
        }
        .padding(32)
        .frame(width: 560, height: 420)
        .background(onboardingBackground)
        .foregroundStyle(.primary)
        .onAppear(perform: refreshAPIKeyState)
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch currentPage {
        case 0:
            firstScreen
        case 1:
            safetyScreen
        default:
            apiKeyScreen
        }
    }

    private var firstScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            centeredSymbol("sparkles", size: 64)

            VStack(alignment: .leading, spacing: 12) {
                Text("Your Mac collects junk.\nPurge cleans it safely.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    """
                    Over time your Mac fills up with leftover files from apps, \
                    coding projects, and system processes. Purge finds them, \
                    explains what they are in plain English, and only removes \
                    what is safe.
                    """
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var safetyScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How Purge decides what is safe")
                .font(.system(.title2, design: .rounded).weight(.bold))

            Text("Every item is tagged before you delete anything.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                safetyTagRow(
                    level: .safe,
                    description: "Always regenerated automatically. Nothing is lost."
                )
                safetyTagRow(
                    level: .medium,
                    description: "Safe to delete but may cause minor inconvenience."
                )
                safetyTagRow(
                    level: .danger,
                    description: "Could break something. Leave it alone."
                )
                safetyTagRow(
                    level: .unknown,
                    description: "Purge could not identify this. We recommend skipping it."
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var apiKeyScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            centeredSymbol("cpu", size: 48)
                .padding(.bottom, 2)

            Text("Smarter identification with AI")
                .font(.system(.title2, design: .rounded).weight(.bold))

            Text(
                """
                Purge uses OpenRouter to explain unknown cache folders in \
                plain English. It only calls AI when needed and saves \
                results permanently so each folder is only looked up once.
                """
            )
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    apiKeySecureField

                    if hasStoredAPIKey {
                        keySavedBadge
                    }

                    Button("Save") {
                        saveAPIKeyAndComplete()
                    }
                    .controlSize(.small)
                    .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Your key is stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Spacer()

            if currentPage == 2 {
                if hasStoredAPIKey {
                    Button {
                        complete()
                    } label: {
                        Text("Done →")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip for now") {
                        complete()
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Skip") {
                    complete()
                }
                .buttonStyle(.plain)

                Button {
                    advance()
                } label: {
                    Text("Next →")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var apiKeySecureField: some View {
        SecureField("Paste your API key here", text: $apiKeyText)
            .textFieldStyle(.roundedBorder)
            .focused($apiKeyFieldFocused)
            .onSubmit(saveAPIKeyAndComplete)
            .onChange(of: apiKeyFieldFocused) { isFocused in
                if isFocused {
                    apiKeyError = nil
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keySavedBadge: some View {
        Label("Key saved", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private var onboardingBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.11),
                Color(red: 0.05, green: 0.06, blue: 0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var openRouterKeysURL: URL {
        URL(string: "https://openrouter.ai/settings/keys")!
    }

    private func centeredSymbol(_ name: String, size: CGFloat) -> some View {
        HStack {
            Spacer()
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Spacer()
        }
        .accessibilityHidden(true)
    }

    private func safetyTagRow(level: SafetyLevel, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(level.color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(level.displayName)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func advance() {
        if currentPage == 2 {
            completeFromAPIKeyScreen()
            return
        }

        if currentPage == 0 {
            hasCompletedOnboarding = true
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            currentPage += 1
        }
    }

    private func completeFromAPIKeyScreen() {
        let trimmed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard validateAndSaveAPIKey(trimmed) else { return }
        }

        complete()
    }

    private func complete() {
        hasCompletedOnboarding = true
        onComplete()
    }

    private func refreshAPIKeyState() {
        hasStoredAPIKey = KeychainStore.read(key: "openrouter-api-key") != nil
        apiKeyText = ""
        apiKeyError = nil
    }

    private func saveAPIKeyAndComplete() {
        let trimmed = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard validateAndSaveAPIKey(trimmed) else { return }
        complete()
    }

    @discardableResult
    private func validateAndSaveAPIKey(_ trimmed: String) -> Bool {
        guard OpenRouterExplanationClient.looksLikeAPIKey(trimmed) else {
            apiKeyError = "This doesn't look like a valid OpenRouter API key"
            return false
        }

        do {
            try KeychainStore.save(key: "openrouter-api-key", value: trimmed)
            hasStoredAPIKey = true
            apiKeyText = ""
            apiKeyError = nil
            apiKeyFieldFocused = false
            return true
        } catch {
            apiKeyError = "We couldn't save this API key. Please try again."
            return false
        }
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false), onComplete: {})
}
