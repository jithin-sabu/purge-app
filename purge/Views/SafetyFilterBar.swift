import AppKit
import SwiftUI

// MARK: - Filter & sort

enum SafetyFilter: String, CaseIterable, Identifiable {
    case all
    case safe
    case checkFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return String(localized: "All")
        case .safe: return String(localized: "Safe to Clean")
        case .checkFirst: return String(localized: "Check First")
        }
    }

    /// Returns `true` when the item should appear under this filter.
    /// Items tagged `.unknown` are silently excluded from every filter.
    func matches(_ safetyInfo: SafetyInfo) -> Bool {
        if safetyInfo.level == .unknown { return false }
        switch self {
        case .all: return true
        case .safe: return safetyInfo.level == .safe
        case .checkFirst: return safetyInfo.level == .medium
        }
    }

    /// Cmd+1 … Cmd+3
    var shortcutDigit: Character {
        switch self {
        case .all: return "1"
        case .safe: return "2"
        case .checkFirst: return "3"
        }
    }

    func tooltipHint(extra: String = "") -> String {
        let suffix = extra.isEmpty ? "" : String(localized: " \(extra)")
        switch self {
        case .all: return String(localized: "Show all items\(suffix) (Cmd+1)")
        case .safe: return String(localized: "Show safe items\(suffix) (Cmd+2)")
        case .checkFirst: return String(localized: "Show check-first items\(suffix) (Cmd+3)")
        }
    }

    func chipSymbolName(isSelected: Bool) -> String {
        switch self {
        case .all: return isSelected ? "square.grid.2x2.fill" : "square.grid.2x2"
        case .safe: return SafetyLevel.safe.symbolName(filled: isSelected)
        case .checkFirst: return SafetyLevel.medium.symbolName(filled: isSelected)
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case sizeDesc
    case sizeAsc
    case dateNewest
    case dateOldest
    case nameAZ

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sizeDesc: return String(localized: "Size (largest first)")
        case .sizeAsc: return String(localized: "Size (smallest first)")
        case .dateNewest: return String(localized: "Date modified (newest first)")
        case .dateOldest: return String(localized: "Date modified (oldest first)")
        case .nameAZ: return String(localized: "Name (A to Z)")
        }
    }

    var shortDisplayName: String {
        switch self {
        case .sizeDesc: return String(localized: "Largest")
        case .sizeAsc: return String(localized: "Smallest")
        case .dateNewest: return String(localized: "Newest")
        case .dateOldest: return String(localized: "Oldest")
        case .nameAZ: return String(localized: "Name")
        }
    }
}

// MARK: - Tri-state checkbox (Select All)

enum SelectAllTriState {
    case none
    case mixed
    case all
}

struct TriStateCheckbox: NSViewRepresentable {
    var title: String
    var state: SelectAllTriState
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func toggled(_ sender: NSButton) {
            action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: NSLocalizedString(title, comment: "Select all checkbox"), target: context.coordinator, action: #selector(Coordinator.toggled))
        button.allowsMixedState = true
        button.contentTintColor = AppColors.controlAccentNSColor
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = NSLocalizedString(title, comment: "Select all checkbox")
        button.isEnabled = isEnabled
        button.contentTintColor = AppColors.controlAccentNSColor
        switch state {
        case .none: button.state = .off
        case .mixed: button.state = .mixed
        case .all: button.state = .on
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - Select All, safe rows first

/// The Select All checkbox for App Caches and Dev Tools, with the link that adds
/// the Check First rows on the All filter. See `SafeFirstSelectAll`.
struct SafeFirstSelectAllControl<Key: Hashable>: View {
    let model: SafeFirstSelectAll<Key>
    let apply: (SafeFirstSelectAll<Key>.Change) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
            TriStateCheckbox(title: model.title, state: model.state) {
                apply(model.toggled())
            }
            .fixedSize()
            .disabled(!model.isEnabled)

            if let link = model.checkFirstLink {
                Button(link.title) {
                    apply(link.change)
                }
                .buttonStyle(.purge(.quiet, size: .small))
                .help("Check First items may hold something you'd miss. Look them over before cleaning.")
                .transition(.opacity)
            }
        }
        // As tall as the link's button, so the checkbox stays put as the link comes and goes.
        .frame(minHeight: 24)
    }
}

// MARK: - Toolbar row (chips + sort + bulk action)

struct FilterSortToolbar: View {
    @Binding var safetyFilter: SafetyFilter
    @Binding var sortOption: SortOption

    /// Precomputed counts per chip (updates live with scan).
    let chipCounts: [SafetyFilter: Int]

    let selectedInScopeCount: Int
    var selectedInScopeBytes: Int64 = 0
    let isDeleting: Bool

    let onCleanSelected: () -> Void

    /// When true (App Caches), chips and sort/bulk sit on separate rows with a horizontally scrolling chip row.
    var useStackedLayout: Bool = false
    var showsControlsRow: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bulkTitle: String? {
        String(localized: "Clean Selected")
    }

    private var bulkDisabled: Bool {
        selectedInScopeCount == 0 || isDeleting
    }

    var body: some View {
        Group {
            if useStackedLayout {
                stackedToolbarBody
            } else {
                compactToolbarBody
            }
        }
    }

    private var stackedToolbarBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SafetyFilter.allCases) { filter in
                        safetyChip(filter)
                    }
                }
                .padding(.vertical, 2)
            }
            .disableScrollClippingWhenAvailable()
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)

            if showsControlsRow {
                HStack(alignment: .center, spacing: 10) {
                    AppSortMenu(selection: $sortOption)

                    Spacer(minLength: 8)

                    if let title = bulkTitle {
                        cleanSelectedBulkButton(title: title)
                    }
                }
            }
        }
    }

    private var compactToolbarBody: some View {
        HStack(alignment: .center, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SafetyFilter.allCases) { filter in
                        safetyChip(filter)
                    }
                }
            }
            .disableScrollClippingWhenAvailable()
            .frame(maxWidth: .infinity, alignment: .leading)

            AppSortMenu(selection: $sortOption)

            if let title = bulkTitle {
                cleanSelectedBulkButton(title: title)
            }
        }
        .padding(.horizontal, 4)
    }

    private func cleanSelectedBulkButton(title: String) -> some View {
        Button {
            onCleanSelected()
        } label: {
            AnimatedDeleteActionLabel(
                inactiveTitle: title,
                activeTitle: title,
                selectedCount: selectedInScopeCount,
                selectedBytes: selectedInScopeBytes
            )
        }
        .buttonStyle(.purge(.primary))
        .disabled(bulkDisabled)
        .fixedSize()
    }

    private func safetyChip(_ filter: SafetyFilter) -> some View {
        let count = chipCounts[filter] ?? 0
        let isOn = safetyFilter == filter

        return Button {
            select(filter)
        } label: {
            FilterChip(
                style: .tab,
                label: filter.displayName,
                isSelected: isOn,
                tier: filter.chipTier,
                leadingSystemImage: filter.chipSymbolName(isSelected: isOn),
                count: count
            )
            .opacity(count == 0 && !isOn ? 0.45 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.displayName), \(count) items")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(filter.tooltipHint())
        .keyboardShortcut(KeyEquivalent(filter.shortcutDigit), modifiers: .command)
    }

    private func select(_ filter: SafetyFilter) {
        if reduceMotion {
            safetyFilter = filter
        } else {
            withAnimation(.easeInOut(duration: 0.5)) {
                safetyFilter = filter

            }
        }
    }
}

private extension View {
    @ViewBuilder
    func disableScrollClippingWhenAvailable() -> some View {
        if #available(macOS 14.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }
}
