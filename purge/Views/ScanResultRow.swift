import AppKit
import SwiftUI

private struct ScanRowPlaceholderAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var scanRowPlaceholderAppearance: Bool {
        get { self[ScanRowPlaceholderAppearanceKey.self] }
        set { self[ScanRowPlaceholderAppearanceKey.self] = newValue }
    }
}

struct ScanResultRow: View {
    @Binding var isSelected: Bool
    let primaryLabel: String
    let formattedSize: String
    let safetyInfo: SafetyInfo
    /// Brand or static row icon; re-resolves for light/dark when using cache/dev/project sources.
    let brandIcon: AdaptiveBrandIconImage.Source?
    /// Small footer line (e.g. artifact kind tag).
    let detailCaption: String?
    let reinstallSafety: ReinstallSafetyStatus?
    let showUncommittedRepoChanges: Bool

    /// Clears a legacy manual category override. When nil, the corresponding
    /// badge is hidden.
    let onResetToAutomatic: (() -> Void)?
    let isUserOverride: Bool
    /// When `false`, the row checkbox is disabled (e.g. high-risk items that should not participate in bulk select).
    var allowsBulkSelection: Bool = true
    /// When `false`, hides the row checkbox; selection may still be driven by a parent control (e.g. project group header).
    var showsBulkCheckbox: Bool = true
    /// When true, the trailing size shows a skeleton placeholder (post-scan enrichment).
    var isMetadataPending: Bool = false
    /// When false, the row renders without its own card chrome (for nested rows inside a parent card).
    var showsCardChrome: Bool = true
    /// When false, no leading icon column is shown (e.g. expanded project artifact rows).
    var showsLeadingIcon: Bool = true

    @Environment(\.scanRowPlaceholderAppearance) private var rendersAsPlaceholder

    private var statusLabel: String {
        safetyInfo.level.displayName
    }

    private var statusTone: AppBadge.Tone {
        switch safetyInfo.level {
        case .safe: return .safe
        case .medium: return .warning
        case .unknown: return .neutral
        }
    }

    private var canSelectForBulk: Bool {
        allowsBulkSelection
    }

    private var showsRowCheckbox: Bool {
        showsBulkCheckbox && allowsBulkSelection
    }

    private var canTapRowToToggleSelection: Bool {
        showsBulkCheckbox && allowsBulkSelection
    }

    private var hasExtraBadges: Bool {
        isUserOverride || detailCaption != nil || showsReinstallBadge || showUncommittedRepoChanges
    }

    private var showsReinstallBadge: Bool {
        guard let reinstallSafety else { return false }
        return reinstallSafety != .notApplicable
    }

    init(
        isSelected: Binding<Bool>,
        primaryLabel: String,
        formattedSize: String,
        safetyInfo: SafetyInfo,
        brandIcon: AdaptiveBrandIconImage.Source?,
        detailCaption: String? = nil,
        reinstallSafety: ReinstallSafetyStatus? = nil,
        showUncommittedRepoChanges: Bool = false,
        onResetToAutomatic: (() -> Void)? = nil,
        isUserOverride: Bool = false,
        allowsBulkSelection: Bool = true,
        showsBulkCheckbox: Bool = true,
        isMetadataPending: Bool = false,
        showsCardChrome: Bool = true,
        showsLeadingIcon: Bool = true
    ) {
        self._isSelected = isSelected
        self.primaryLabel = primaryLabel
        self.formattedSize = formattedSize
        self.safetyInfo = safetyInfo
        self.brandIcon = brandIcon
        self.detailCaption = detailCaption
        self.reinstallSafety = reinstallSafety
        self.showUncommittedRepoChanges = showUncommittedRepoChanges
        self.onResetToAutomatic = onResetToAutomatic
        self.isUserOverride = isUserOverride
        self.allowsBulkSelection = allowsBulkSelection
        self.showsBulkCheckbox = showsBulkCheckbox
        self.isMetadataPending = isMetadataPending
        self.showsCardChrome = showsCardChrome
        self.showsLeadingIcon = showsLeadingIcon
    }

    var body: some View {
        rowBody
            .modifier(ScanResultRowChrome(showsCardChrome: showsCardChrome, canSelectForBulk: canSelectForBulk))
    }

    private var rowBody: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsRowCheckbox {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .tint(AppColors.buttonPrimaryBg)
            }

            if canTapRowToToggleSelection {
                Button {
                    isSelected.toggle()
                } label: {
                    rowMainContent
                }
                .buttonStyle(.plain)
            } else {
                rowMainContent
            }

            Spacer(minLength: 12)

            trailingColumn
        }
        .padding(.horizontal, showsCardChrome ? 14 : 0)
        .padding(.vertical, showsCardChrome ? 12 : 8)
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: showsLeadingIcon ? 12 : 0) {
            if showsLeadingIcon {
                rowIconView
            }
            rowTextColumn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowIconView: some View {
        if rendersAsPlaceholder {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(SkeletonOpacity.light))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                .shimmering()
        } else if let brandIcon {
            AdaptiveBrandIconImage(source: brandIcon)
        }
    }

    @ViewBuilder
    private var rowTextColumn: some View {
        if rendersAsPlaceholder {
            rowPlaceholderTextColumn
        } else {
            rowLoadedTextColumn
        }
    }

    private var rowLoadedTextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryLabel)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Text(safetyInfo.explanation)
                .lineLimit(3)
                .truncationMode(.tail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(
                    minHeight: ScanResultRow.subheadlineTwoLineHeight,
                    alignment: .topLeading
                )

            if hasExtraBadges {
                badgesRow
            }
        }
    }

    private var rowPlaceholderTextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            SkeletonFillBar(height: ScanResultRow.headlineOneLineHeight, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 4) {
                SkeletonFillBar(height: 10)
                SkeletonFillBar(height: 10)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: ScanResultRow.subheadlineTwoLineHeight,
                alignment: .topLeading
            )

            if hasExtraBadges {
                SkeletonBar(width: 96, height: 16, cornerRadius: AppStyle.Radius.chip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering()
    }

    @ViewBuilder
    private var trailingColumn: some View {
        if rendersAsPlaceholder {
            trailingMetadataSkeleton
        } else {
            loadedTrailingColumn
        }
    }

    private var loadedTrailingColumn: some View {
        ScanContentCrossfade(isLoading: isMetadataPending) {
            trailingMetadataSkeleton
        } loaded: {
            VStack(alignment: .trailing, spacing: 8) {
                Text(formattedSize)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                AppBadge(text: statusLabel, tone: statusTone)
            }
        }
    }

    private var trailingMetadataSkeleton: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SkeletonBar(width: 56, height: ScanResultRow.subheadlineOneLineHeight, cornerRadius: 4)
            SkeletonBar(width: 92, height: 18, cornerRadius: AppStyle.Radius.chip)
        }
        .shimmering()
    }

    /// Single-line height for `.headline` title text.
    static let headlineOneLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    /// Single-line height for `.subheadline` trailing size text.
    static let subheadlineOneLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    @ViewBuilder
    private var badgesRow: some View {
        HStack(alignment: .center, spacing: 6) {
            extraBadges
        }
    }

    /// Reserves exactly two lines of subheadline-sized text so rows with short
    /// explanations don't shrink between the placeholder and loaded states.
    static let subheadlineTwoLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let lineHeight = font.ascender - font.descender + font.leading
        return ceil(lineHeight * 2)
    }()

    @ViewBuilder
    private var extraBadges: some View {
        if isUserOverride {
            userOverrideBadge
        }
        if let detailCaption {
            AppBadge(text: detailCaption, tone: .neutral)
        }
        if let reinstallSafety {
            switch reinstallSafety {
            case .reinstallable:
                AppBadge(text: "Can be rebuilt", tone: .safe)
            case .missingLockfile:
                AppBadge(text: "Check support files", tone: .warning)
            case .notApplicable:
                EmptyView()
            }
        }
        if showUncommittedRepoChanges {
            AppBadge(text: "Local changes nearby", tone: .warning)
        }
    }

    @ViewBuilder
    private var userOverrideBadge: some View {
        if let onResetToAutomatic {
            Button {
                onResetToAutomatic()
            } label: {
                AppBadge(text: "Manual category", tone: .accent)
            }
            .buttonStyle(.plain)
            .help("Reset to automatic")
        } else {
            AppBadge(text: "Manual category", tone: .accent)
        }
    }
}

// MARK: - Row chrome

struct ScanRowCardChrome: ViewModifier {
    var showsCardChrome: Bool = true
    var canSelectForBulk: Bool = true

    func body(content: Content) -> some View {
        if showsCardChrome {
            content
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous))
                .opacity(canSelectForBulk ? 1 : 0.55)
        } else {
            content
                .opacity(canSelectForBulk ? 1 : 0.55)
        }
    }
}

private typealias ScanResultRowChrome = ScanRowCardChrome

// MARK: - Placeholder

extension ScanResultRow {
    /// Renders a `ScanResultRow` as a redacted, shimmering placeholder that matches
    /// the geometry of a real loaded row. Used by `ScanListSkeletonPlaceholder` so
    /// the loading-to-loaded crossfade has no layout shift.
    ///
    /// - Parameter showsExtraBadges: When `true`, reserves the optional badges row
    ///   beneath the subtitle (e.g. project artifact tags). Default `false` matches
    ///   typical App Cache and dev tool rows.
    static func placeholder(seed: Int, showsExtraBadges: Bool = false) -> some View {
        ScanResultRowPlaceholder(seed: seed, showsExtraBadges: showsExtraBadges)
    }
}

private struct ScanResultRowPlaceholder: View {
    let seed: Int
    var showsExtraBadges: Bool

    var body: some View {
        ScanResultRow(
            isSelected: .constant(false),
            primaryLabel: Self.primaryLabel(for: seed),
            formattedSize: Self.formattedSize(for: seed),
            safetyInfo: Self.safetyInfo(for: seed, showsExtraBadges: showsExtraBadges),
            brandIcon: nil,
            detailCaption: showsExtraBadges ? Self.detailCaption(for: seed) : nil,
            reinstallSafety: nil,
            showUncommittedRepoChanges: false,
            onResetToAutomatic: nil,
            isUserOverride: false,
            allowsBulkSelection: true,
            isMetadataPending: false
        )
        .environment(\.scanRowPlaceholderAppearance, true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let primaryLabels: [String] = [
        "Sample Application",
        "Another Cache Folder",
        "A Slightly Longer Item Name",
        "Short Name",
        "Medium-Length Title Here",
        "Yet Another Sample Item",
        "Compact",
        "Placeholder Application Title"
    ]

    private static let explanations: [String] = [
        "This cache rebuilds automatically the next time the application launches and is generally safe to remove without losing user data.",
        "Stored derived data and indexes that the tool will regenerate on the next build, so deleting it only costs a one-time rebuild.",
        "Holds intermediate artifacts that are reproducible from source. Removing them frees disk space at the cost of the next compile or fetch.",
        "Temporary files that the system or app keeps around for performance. They are recreated on demand and do not contain user content."
    ]

    private static let detailCaptions: [String] = [
        "Cache",
        "Build folder",
        "Derived data",
        "Module store"
    ]

    private static let sizeStrings: [String] = [
        "123 MB",
        "1.2 GB",
        "45 MB",
        "678 MB",
        "2.4 GB"
    ]

    private static func primaryLabel(for seed: Int) -> String {
        primaryLabels[abs(seed) % primaryLabels.count]
    }

    private static func detailCaption(for seed: Int) -> String {
        detailCaptions[abs(seed) % detailCaptions.count]
    }

    private static func formattedSize(for seed: Int) -> String {
        sizeStrings[abs(seed) % sizeStrings.count]
    }

    private static func safetyInfo(for seed: Int, showsExtraBadges: Bool) -> SafetyInfo {
        let levels: [SafetyLevel] = [.safe, .medium, .unknown]
        let level = showsExtraBadges ? levels[abs(seed) % levels.count] : .safe
        let explanation = explanations[abs(seed) % explanations.count]
        return SafetyInfo(
            level: level,
            headline: primaryLabel(for: seed),
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
