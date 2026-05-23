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
    /// When nil, a generic folder icon is shown.
    let icon: NSImage?
    let onRequestUnknownDelete: (() -> Void)?
    /// Small footer line (e.g. artifact kind tag).
    let detailCaption: String?
    let reinstallSafety: ReinstallSafetyStatus?
    let showUncommittedRepoChanges: Bool

    /// Per-row recategorization entry points. When nil, the corresponding menu
    /// item or badge is hidden.
    let onRecategorize: (() -> Void)?
    let onMarkSafe: (() -> Void)?
    let onMarkMedium: (() -> Void)?
    let onMarkDanger: (() -> Void)?
    let onResetToAutomatic: (() -> Void)?
    let isUserOverride: Bool
    /// When `false`, the row checkbox is disabled (e.g. high-risk items that should not participate in bulk select).
    var allowsBulkSelection: Bool = true
    /// When true, trailing size and safety badge show skeleton placeholders (post-scan enrichment).
    var isMetadataPending: Bool = false

    @Environment(\.scanRowPlaceholderAppearance) private var rendersAsPlaceholder

    private var statusLabel: String {
        safetyInfo.level.displayName
    }

    private var statusTone: AppBadge.Tone {
        switch safetyInfo.level {
        case .safe: return .safe
        case .medium: return .warning
        case .danger: return .danger
        case .unknown: return .neutral
        }
    }

    private var offersUnknownDeletion: Bool {
        safetyInfo.level == .unknown && onRequestUnknownDelete != nil
    }

    private var canSelectForBulk: Bool {
        allowsBulkSelection
    }

    private var resolvedIcon: NSImage {
        if let icon {
            return icon
        }
        return NSWorkspace.shared.icon(forFileType: "public.folder")
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
        icon: NSImage?,
        onRequestUnknownDelete: (() -> Void)?,
        detailCaption: String? = nil,
        reinstallSafety: ReinstallSafetyStatus? = nil,
        showUncommittedRepoChanges: Bool = false,
        onRecategorize: (() -> Void)? = nil,
        onMarkSafe: (() -> Void)? = nil,
        onMarkMedium: (() -> Void)? = nil,
        onMarkDanger: (() -> Void)? = nil,
        onResetToAutomatic: (() -> Void)? = nil,
        isUserOverride: Bool = false,
        allowsBulkSelection: Bool = true,
        isMetadataPending: Bool = false
    ) {
        self._isSelected = isSelected
        self.primaryLabel = primaryLabel
        self.formattedSize = formattedSize
        self.safetyInfo = safetyInfo
        self.icon = icon
        self.onRequestUnknownDelete = onRequestUnknownDelete
        self.detailCaption = detailCaption
        self.reinstallSafety = reinstallSafety
        self.showUncommittedRepoChanges = showUncommittedRepoChanges
        self.onRecategorize = onRecategorize
        self.onMarkSafe = onMarkSafe
        self.onMarkMedium = onMarkMedium
        self.onMarkDanger = onMarkDanger
        self.onResetToAutomatic = onResetToAutomatic
        self.isUserOverride = isUserOverride
        self.allowsBulkSelection = allowsBulkSelection
        self.isMetadataPending = isMetadataPending
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if canSelectForBulk {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }

            if canSelectForBulk {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(canSelectForBulk ? 1 : 0.55)
        .contextMenu {
            rowContextMenu
        }
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: 12) {
            rowIconView
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
        } else {
            Image(nsImage: resolvedIcon)
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                .lineLimit(2)
                .truncationMode(.tail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(
                    minHeight: ScanResultRow.subheadlineTwoLineHeight,
                    alignment: .topLeading
                )

            if hasExtraBadges || isMetadataPending {
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
            VStack(alignment: .trailing, spacing: 8) {
                SkeletonBar(width: 44, height: 10, cornerRadius: 4)
                SkeletonBar(width: 72, height: 18, cornerRadius: AppStyle.Radius.chip)
            }
            .shimmering()
        } else {
            loadedTrailingColumn
        }
    }

    private var loadedTrailingColumn: some View {
        ScanContentCrossfade(isLoading: isMetadataPending) {
            VStack(alignment: .trailing, spacing: 8) {
                SkeletonBar(width: 44, height: 10, cornerRadius: 4)
                    .shimmering()
                SkeletonBar(width: 72, height: 18, cornerRadius: AppStyle.Radius.chip)
                    .shimmering()
            }
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

    /// Single-line height for `.headline` title text.
    static let headlineOneLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    @ViewBuilder
    private var badgesRow: some View {
        HStack(alignment: .center, spacing: 6) {
            extraBadges
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        if let onRecategorize {
            Button("Recategorize") {
                onRecategorize()
            }
        }

        if hasAnyMarkAction {
            Divider()
            if let onMarkSafe, safetyInfo.level != .safe {
                Button("Mark as Safe to Clean") { onMarkSafe() }
            }
            if let onMarkMedium, safetyInfo.level != .medium {
                Button("Mark as Check First") { onMarkMedium() }
            }
            if let onMarkDanger, safetyInfo.level != .danger {
                Button("Mark as Do Not Delete") { onMarkDanger() }
            }
        }

        if isUserOverride, let onResetToAutomatic {
            Divider()
            Button("Reset to automatic") { onResetToAutomatic() }
        }

        if offersUnknownDeletion {
            Divider()
            Button("Delete…", role: .destructive) {
                onRequestUnknownDelete?()
            }
        }
    }

    private var hasAnyMarkAction: Bool {
        onMarkSafe != nil || onMarkMedium != nil || onMarkDanger != nil
    }

    /// Reserves exactly two lines of subheadline-sized text so rows with short
    /// explanations don't shrink between the placeholder and loaded states.
    static let subheadlineTwoLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let lineHeight = font.ascender - font.descender + font.leading
        return ceil(lineHeight * 2)
    }()

    private var extraBadges: some View {
        ScanContentCrossfade(isLoading: isMetadataPending) {
            SkeletonBar(width: 96, height: 16, cornerRadius: AppStyle.Radius.chip)
                .shimmering()
        } loaded: {
            Group {
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
            icon: nil,
            onRequestUnknownDelete: nil,
            detailCaption: showsExtraBadges ? Self.detailCaption(for: seed) : nil,
            reinstallSafety: nil,
            showUncommittedRepoChanges: false,
            onRecategorize: nil,
            onMarkSafe: nil,
            onMarkMedium: nil,
            onMarkDanger: nil,
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
        let levels: [SafetyLevel] = [.safe, .medium, .danger, .unknown]
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
