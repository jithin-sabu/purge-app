import AppKit
import SwiftUI

// MARK: - Filter & sort

enum SafetyFilter: String, CaseIterable, Identifiable {
    case all
    case safe
    case medium
    case danger
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .safe: return "Safe to Clean"
        case .medium: return "Check First"
        case .danger: return "Do Not Delete"
        case .unknown: return "Not Sure"
        }
    }

    var safetyLevel: SafetyLevel? {
        switch self {
        case .all: return nil
        case .safe: return .safe
        case .medium: return .medium
        case .danger: return .danger
        case .unknown: return .unknown
        }
    }

    func matches(_ safetyInfo: SafetyInfo) -> Bool {
        guard let safetyLevel else { return true }
        return safetyInfo.level == safetyLevel
    }

    /// Cmd+1 … Cmd+5
    var shortcutDigit: Character {
        switch self {
        case .all: return "1"
        case .safe: return "2"
        case .medium: return "3"
        case .danger: return "4"
        case .unknown: return "5"
        }
    }

    func tooltipHint(extra: String = "") -> String {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        switch self {
        case .all: return "Show all items\(suffix) (Cmd+1)"
        case .safe: return "Show safe items\(suffix) (Cmd+2)"
        case .medium: return "Show check-first items\(suffix) (Cmd+3)"
        case .danger: return "Show do-not-delete items\(suffix) (Cmd+4)"
        case .unknown: return "Show not-sure items\(suffix) (Cmd+5)"
        }
    }

    /// SF Symbols shown in filter chips (paired with labels for non-color cues).
    var chipSymbolName: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .safe: return "checkmark.shield.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    /// Fills tuned for **WCAG 2.1 AA** (~4.5:1) with white labels at caption size on macOS dark/light appearances.
    var activeFillColor: Color {
        switch self {
        case .all: return Color(red: 0 / 255, green: 71 / 255, blue: 171 / 255)
        case .safe: return Color(red: 13 / 255, green: 110 / 255, blue: 61 / 255)
        case .medium: return Color(red: 169 / 255, green: 68 / 255, blue: 0 / 255)
        case .danger: return Color(red: 179 / 255, green: 32 / 255, blue: 32 / 255)
        case .unknown: return Color(red: 69 / 255, green: 69 / 255, blue: 69 / 255)
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
        case .sizeDesc: return "Size (largest first)"
        case .sizeAsc: return "Size (smallest first)"
        case .dateNewest: return "Date modified (newest first)"
        case .dateOldest: return "Date modified (oldest first)"
        case .nameAZ: return "Name (A to Z)"
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
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggled))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
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

// MARK: - Toolbar row (chips + sort + bulk action)

struct FilterSortToolbar: View {
    @Binding var safetyFilter: SafetyFilter
    @Binding var sortOption: SortOption

    /// Precomputed counts per chip (updates live with scan).
    let chipCounts: [SafetyFilter: Int]

    let selectedInScopeCount: Int
    let isDeleting: Bool

    let onCleanSelected: () -> Void
    var pendingAIResolutionCount: Int = 0

    /// When true (App Caches), chips and sort/bulk sit on separate rows with a horizontally scrolling chip row.
    var useStackedLayout: Bool = false
    var showsControlsRow: Bool = true

    private var bulkTitle: String? {
        "Clean Selected"
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
                HStack(spacing: 6) {
                    ForEach(SafetyFilter.allCases) { filter in
                        safetyChip(filter)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)

            if showsControlsRow {
                HStack(alignment: .center, spacing: 10) {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

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
                HStack(spacing: 6) {
                    ForEach(SafetyFilter.allCases) { filter in
                        safetyChip(filter)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

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
            Label(title, systemImage: "trash.fill")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .disabled(bulkDisabled)
        .fixedSize()
    }

    private func safetyChip(_ filter: SafetyFilter) -> some View {
        let count = chipCounts[filter] ?? 0
        let isOn = safetyFilter == filter
        let label = "\(filter.displayName) (\(count))"

        return Button {
            safetyFilter = filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.chipSymbolName)
                    .font(.footnote.weight(isOn ? .semibold : .regular))
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.caption.weight(isOn ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, useStackedLayout ? 12 : 10)
            .padding(.vertical, useStackedLayout ? 6 : 5)
            .background(
                Capsule().fill(isOn ? filter.activeFillColor : Color.primary.opacity(0.12))
            )
            .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.displayName), \(count) items")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(filter.tooltipHint())
        .keyboardShortcut(KeyEquivalent(filter.shortcutDigit), modifiers: .command)
    }
}
