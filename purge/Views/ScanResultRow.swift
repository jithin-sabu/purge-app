import AppKit
import SwiftUI

struct ScanResultRow: View {
    @Binding var isSelected: Bool
    let primaryLabel: String
    let formattedSize: String
    let dateModifiedLine: String?
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

    @State private var isHoveringRow = false
    @State private var showSafetyPopover = false
    @State private var hoverPopoverWorkItem: DispatchWorkItem?

    private var isAwaitingAI: Bool {
        safetyInfo.explanation == ExplanationResolver.checkingExplanation
    }

    private var statusLabel: String {
        isAwaitingAI ? "🔍 Identifying..." : safetyInfo.level.displayName
    }

    private var statusColor: Color {
        isAwaitingAI ? Color.secondary : safetyInfo.level.color
    }

    private var popoverStatusColor: Color {
        isAwaitingAI ? Color.accentColor : statusColor
    }

    private var popoverExplanation: String {
        if isAwaitingAI {
            return """
            Purge is asking AI to identify this folder.
            This only happens once and the result is saved permanently.
            """
        }

        return safetyInfo.explanation
    }

    /// Unknown rows may still be deleted deliberately; affordance lives in the popover and context menu (not a separate left column).
    private var offersUnknownDeletion: Bool {
        safetyInfo.level == .unknown && !isAwaitingAI && onRequestUnknownDelete != nil
    }

    /// Rows that can toggle selection (checkbox enabled + main row/icon acts as toggle). Unknown is allowed once classification finishes; Do Not Delete can be selected for deliberate cleanup with extra confirmations.
    private var canSelectForBulk: Bool {
        switch safetyInfo.level {
        case .safe, .medium, .danger:
            return true
        case .unknown:
            return !isAwaitingAI
        }
    }

    private var resolvedIcon: NSImage {
        if let icon {
            return icon
        }
        return NSWorkspace.shared.icon(forFileType: "public.folder")
    }

    init(
        isSelected: Binding<Bool>,
        primaryLabel: String,
        formattedSize: String,
        dateModifiedLine: String?,
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
        isUserOverride: Bool = false
    ) {
        self._isSelected = isSelected
        self.primaryLabel = primaryLabel
        self.formattedSize = formattedSize
        self.dateModifiedLine = dateModifiedLine
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
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            controlColumn

            if canSelectForBulk {
                Button {
                    isSelected.toggle()
                } label: {
                    rowMainContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                rowMainContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            rowContextMenu
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHoveringRow ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHoveringRow = hovering
            }
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        if let onRecategorize, !isAwaitingAI {
            Button("This seems wrong — Recategorize") {
                onRecategorize()
            }
        }

        if !isAwaitingAI && hasAnyMarkAction {
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

    /// Dot, icon, labels, size — hover popover attaches here so the checkbox column stays fully clickable.
    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Image(nsImage: resolvedIcon)
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLabel)
                    .font(.headline.weight(.semibold))
                if let dateModifiedLine {
                    Text(dateModifiedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isUserOverride {
                    userOverrideBadge
                }
                if let detailCaption {
                    Text(detailCaption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    if let reinstallSafety {
                        switch reinstallSafety {
                        case .reinstallable:
                            Text("✓ Can be rebuilt")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.green.opacity(0.95))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        case .missingLockfile:
                            Text("⚠ Check support files")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        case .notApplicable:
                            EmptyView()
                        }
                    }
                    if showUncommittedRepoChanges {
                        Text("Unfinished local changes nearby")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Spacer(minLength: 8)

            Text(formattedSize)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .onHover { hovering in
            hoverPopoverWorkItem?.cancel()
            hoverPopoverWorkItem = nil

            if hovering {
                let work = DispatchWorkItem { showSafetyPopover = true }
                hoverPopoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
            } else {
                showSafetyPopover = false
            }
        }
        .popover(isPresented: $showSafetyPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(popoverStatusColor)
                Text(popoverExplanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if offersUnknownDeletion {
                    Divider()
                    Button("Delete…", role: .destructive) {
                        showSafetyPopover = false
                        onRequestUnknownDelete?()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }

    @ViewBuilder
    private var userOverrideBadge: some View {
        HStack(spacing: 4) {
            Text("You categorized this")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let onResetToAutomatic {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Reset to automatic") {
                    onResetToAutomatic()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controlColumn: some View {
        Toggle("", isOn: $isSelected)
            .labelsHidden()
            .disabled(!canSelectForBulk)
    }
}
