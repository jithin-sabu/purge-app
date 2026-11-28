import AppKit
import SwiftUI

/// The Xcode build folders card in Dev Tools (#480) is a small tree: the
/// card's header, its two parts, and the folders in each. Each is a list row
/// of its own, so opening a part inserts rows below it and nothing above
/// moves. The rows draw one card between them.
///
/// Every level has a checkbox, and a thin elbow runs from a parent's checkbox
/// to its first child's. The rows have fixed heights so each elbow can be
/// exact: its two arms are the same length, and it stops the same gap short
/// of both checkboxes. That holds when a child's checkbox sits as far to the
/// right of its parent's as it sits below it, centre to centre, which is what
/// the indents below are.
enum XcodeBuildFolderTree {
    /// The checkbox's own width, the same box every scan row draws.
    static let checkboxSlot: CGFloat = 16
    /// The header's title, two-line summary and checkbox sit in a band just
    /// tall enough for them, measured in the font the interface uses. Any
    /// shorter and SwiftUI drops the summary's second line.
    static let headerContentHeight: CGFloat =
        lineHeight(of: AppStyle.Typography.headline, lines: 1)
            + AppStyle.Spacing.xxSmall
            + lineHeight(of: AppStyle.Typography.metadata, lines: 2)
    /// Above the header's band, and the card's footer row while it is closed.
    static let headerPadding = AppStyle.Spacing.small
    static let childHeight: CGFloat = 40
    /// From the card's checkbox to a part's, centre to centre, both ways.
    static let partIndent = headerContentHeight / 2 + childHeight / 2
    /// From a part's checkbox to a folder's, centre to centre, both ways.
    static let folderIndent = childHeight
    /// Between each end of an elbow and the checkbox it points at.
    static let lineGap = AppStyle.Spacing.small
    static let lineCorner: CGFloat = 12
    /// Where the card's checkbox starts, as on every scan row.
    static let leading = AppStyle.Row.scanCardHorizontalPadding

    /// The height of `lines` lines of `style`: Onest, or the system font where
    /// the interface doesn't use Onest.
    private static func lineHeight(of style: AppStyle.TextStyle, lines: Int) -> CGFloat {
        let usesOnest = AppFonts.usesOnest(for: Bundle.main.preferredLocalizations.first) && AppFonts.register()
        let font = (usesOnest ? NSFont(name: "Onest", size: style.size) : nil) ?? NSFont.systemFont(ofSize: style.size)
        return ceil((font.ascender - font.descender + font.leading) * CGFloat(lines))
    }
}

/// The lower part of an elbow, in the indent in front of a child's checkbox:
/// down from the row's top under the parent's checkbox, a rounded corner,
/// then right to a gap before the child's checkbox.
struct XcodeBuildFolderElbow: Shape {
    func path(in rect: CGRect) -> Path {
        let x = XcodeBuildFolderTree.checkboxSlot / 2
        let corner = XcodeBuildFolderTree.lineCorner
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.midY - corner))
        path.addArc(
            center: CGPoint(x: x + corner, y: rect.midY - corner),
            radius: corner,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - XcodeBuildFolderTree.lineGap, y: rect.midY))
        return path
    }
}

/// The upper part of an elbow, in the parent's row: from a gap under the
/// parent's checkbox down to the row's bottom, where the child's row goes on.
struct XcodeBuildFolderStub: Shape {
    /// The parent checkbox's left edge in the row.
    let checkboxX: CGFloat

    func path(in rect: CGRect) -> Path {
        let x = checkboxX + XcodeBuildFolderTree.checkboxSlot / 2
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.midY + XcodeBuildFolderTree.checkboxSlot / 2 + XcodeBuildFolderTree.lineGap))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        return path
    }
}

private extension Shape {
    func treeLine() -> some View {
        stroke(AppColors.textTertiary, style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}

/// An indent in front of a child row, with the elbow when the row is its
/// parent's first child.
struct XcodeBuildFolderIndent: View {
    let width: CGFloat
    let showsElbow: Bool

    var body: some View {
        Color.clear
            .frame(width: width)
            .overlay {
                if showsElbow { XcodeBuildFolderElbow().treeLine() }
            }
            .accessibilityHidden(true)
    }
}

/// Where a row sits in the card, for its share of the card's corners.
enum XcodeBuildFolderCardSlice {
    case whole, top, middle, bottom

    static func at(_ index: Int, of count: Int) -> XcodeBuildFolderCardSlice {
        if count == 1 { return .whole }
        if index == 0 { return .top }
        return index == count - 1 ? .bottom : .middle
    }

    var hasTop: Bool { self == .whole || self == .top }
    var hasBottom: Bool { self == .whole || self == .bottom }

    /// The same for every row of the card, with no gap above or below, so the
    /// rows meet. The list keeps a row's first insets when they change, so a
    /// header that opened would keep its gap; the gaps around the card are
    /// padding in the first and last rows instead.
    static var listInsets: EdgeInsets {
        var insets = ScanListRowInsets.standard
        insets.top = 0
        insets.bottom = 0
        return insets
    }
}

/// The card's fill behind one row, rounded only where the card's corners are.
struct XcodeBuildFolderCardChrome: ViewModifier {
    let slice: XcodeBuildFolderCardSlice

    private var shape: UnevenRoundedRectangle {
        let radius = AppStyle.Radius.lg
        let top: CGFloat = slice.hasTop ? radius : 0
        let bottom: CGFloat = slice.hasBottom ? radius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        content
            .background { shape.fill(AppColors.fillSecondary) }
            .clipShape(shape)
            // The gap other scan rows get from their insets.
            .padding(.top, slice.hasTop ? ScanListRowInsets.standard.top : 0)
            .padding(.bottom, slice.hasBottom ? ScanListRowInsets.standard.bottom : 0)
    }
}

/// The chevron after a title, which opens and closes what is under it. Inline
/// so the right column keeps the same size and badge edge as every other row.
private struct XcodeBuildFolderChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(AppStyle.Typography.metadata.weight(.semibold))
            .foregroundStyle(AppColors.textSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// The card's header: checkbox, icon, title with its chevron, summary, then
/// size and badge in the same column as the rows around the card.
struct XcodeBuildFolderGroupHeader: View {
    let iconTool: DevTool
    let folderCount: Int
    let bytes: Int64
    let isExpanded: Bool
    let showsStub: Bool
    let selectionState: SelectAllTriState
    let onToggleSelection: () -> Void
    let onToggleExpanded: () -> Void

    private var title: String { String(localized: "Xcode build folders") }

    private var summary: String { Self.summary(folderCount: folderCount) }

    /// The count, where the folders are, and that Xcode makes them again, in
    /// two lines like the explanation on every other scan row. The last
    /// scan's card shows the same text.
    static func summary(folderCount: Int) -> String {
        String(localized: "\(folderCount) folders") + " · " + String(localized: "Built outside Xcode's own folder. \(rebuildNote)")
    }

    /// The build folders' explanation from explanations.json.
    private static let rebuildNote = SafetyInfo.fromExplanationDatabase(
        key: XcodeBuildFolderScanPolicy.explanationKey,
        friendlyFallback: ""
    ).explanation

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            TriStateCheckbox(title: "", state: selectionState, action: onToggleSelection)
                .accessibilityLabel(Text("Select all Xcode build folders"))
                .frame(width: XcodeBuildFolderTree.checkboxSlot)

            HStack(spacing: AppStyle.Spacing.small) {
                AdaptiveBrandIconImage(source: .devTool(iconTool))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    HStack(spacing: AppStyle.Spacing.xSmall) {
                        Text(title)
                            .font(AppStyle.Typography.headline)
                            .lineLimit(1)
                        XcodeBuildFolderChevron(isExpanded: isExpanded)
                    }
                    Text(summary)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title + ". " + summary))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? Text("Hide folders") : Text("Show folders"))
            .accessibilityAction { onToggleExpanded() }

            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xxSmall) {
                Text(formatBytes(bytes))
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .monospacedDigit()
                AppBadge(level: .medium)
            }
        }
        .padding(.horizontal, XcodeBuildFolderTree.leading)
        .frame(height: XcodeBuildFolderTree.headerContentHeight)
        .overlay {
            if showsStub {
                XcodeBuildFolderStub(checkboxX: XcodeBuildFolderTree.leading).treeLine()
                    .accessibilityHidden(true)
            }
        }
        // Nothing below the band: the first part's row meets it, so the elbow
        // runs on. The card's footer row holds the space under the card, so
        // no row changes height when the card opens or closes.
        .padding(.top, XcodeBuildFolderTree.headerPadding)
    }
}

/// One part of the card: the folders whose project is gone, or the ones whose
/// project is still on this Mac. Its checkbox ticks that part alone.
struct XcodeBuildFolderPartHeader: View {
    let part: XcodeBuildFolderGroup.Part
    let folderCount: Int
    let bytes: Int64
    let isExpanded: Bool
    let showsElbow: Bool
    let showsStub: Bool
    let selectionState: SelectAllTriState
    let onToggleSelection: () -> Void
    let onToggleExpanded: () -> Void

    private var title: String {
        switch part {
        case .projectGone: String(localized: "Project no longer on this Mac")
        case .projectHere: String(localized: "Project still on this Mac")
        }
    }

    private var count: String { String(localized: "\(folderCount) folders") }

    var body: some View {
        HStack(spacing: 0) {
            XcodeBuildFolderIndent(width: XcodeBuildFolderTree.partIndent, showsElbow: showsElbow)
            HStack(spacing: AppStyle.Spacing.small) {
                TriStateCheckbox(title: "", state: selectionState, action: onToggleSelection)
                    .accessibilityLabel(Text("Select \(title)"))
                    .frame(width: XcodeBuildFolderTree.checkboxSlot)

                HStack(spacing: AppStyle.Spacing.xSmall) {
                    Text(title)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                    Text(count)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                    XcodeBuildFolderChevron(isExpanded: isExpanded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpanded)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title + ". " + count))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? Text("Hide folders") : Text("Show folders"))
                .accessibilityAction { onToggleExpanded() }

                Text(formatBytes(bytes))
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, XcodeBuildFolderTree.leading)
        .frame(height: XcodeBuildFolderTree.childHeight)
        .overlay {
            if showsStub {
                XcodeBuildFolderStub(checkboxX: XcodeBuildFolderTree.leading + XcodeBuildFolderTree.partIndent).treeLine()
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One folder in an open part, on one line: checkbox, the folder's name, the
/// project it was built from and when, and its size. The card's badge and the
/// part's title already say Check First and whether the project is gone, so
/// the row doesn't repeat them. A tap anywhere ticks it, as on every scan row.
struct XcodeBuildFolderRow: View {
    let facts: XcodeBuildFolderScanPolicy.FolderFacts?
    let fallbackName: String
    let formattedSize: String
    let isSelected: Bool
    let showsElbow: Bool
    let onToggle: () -> Void

    private var name: String { facts?.name ?? fallbackName }

    private var detail: String? {
        guard let facts, let project = facts.project else { return nil }
        guard let lastBuilt = facts.lastBuilt else { return project }
        return project + " · " + lastBuilt.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Under the card's checkbox, then under the part's.
            XcodeBuildFolderIndent(width: XcodeBuildFolderTree.partIndent, showsElbow: false)
            XcodeBuildFolderIndent(width: XcodeBuildFolderTree.folderIndent, showsElbow: showsElbow)
            HStack(spacing: AppStyle.Spacing.small) {
                // Non-interactive, as on scan rows: the row's tap publishes it.
                Toggle("", isOn: .constant(isSelected))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .tint(AppColors.actionPrimary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .frame(width: XcodeBuildFolderTree.checkboxSlot)

                HStack(spacing: AppStyle.Spacing.xSmall) {
                    Text(name)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let detail {
                        Text(detail)
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formattedSize)
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, XcodeBuildFolderTree.leading)
        .frame(height: XcodeBuildFolderTree.childHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [name, detail, formattedSize].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onToggle() }
    }
}
