import AppKit
import SwiftUI

/// The Map side of the drill-in (#220): the same figures as the list as a
/// squarified treemap, one level per view. The top level is the groups with
/// macOS and the remainder; a group opens to its folders over the floor plus
/// one tile for everything smaller. Drawn in a Canvas with hit testing by hand,
/// one accessibility child per tile, a breadcrumb above and a detail strip
/// below for the tile under the pointer. Secondary to the list: selection is
/// shared both ways, and there is no action here the list does not have.
struct EverythingElseMapCard: View {
    let breakdown: EverythingElseBreakdown
    @Binding var openGroup: EverythingElseGroup?
    @Binding var selectedFolderPath: String?
    let linkedState: (String) -> OverviewLinkedRowState

    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?
    /// Each level's last order, so a re-measure resizes tiles without reshuffling.
    @State private var orders: [String: [String]] = [:]
    /// Where the zoom grows from: the tile that was opened, as a unit point.
    @State private var zoomAnchor: UnitPoint = .center

    private static let height: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            breadcrumb
            GeometryReader { geometry in
                let level = currentLevel
                let plan = TreemapLayout.plan(
                    level.items,
                    in: CGRect(origin: .zero, size: geometry.size),
                    floorWeight: Double(level.floorBytes),
                    previousOrder: orders[level.id]
                )
                EverythingElseTreemap(
                    level: level,
                    plan: plan,
                    hoveredID: $hoveredID,
                    selectedID: selectedID,
                    onSelect: select,
                    onOpen: open
                )
                .onChange(of: plan.order) { order in
                    orders[level.id] = order
                }
                .onAppear { orders[level.id] = plan.order }
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous))
            .id(currentLevel.id)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .scale(scale: 0.55, anchor: zoomAnchor).combined(with: .opacity),
                removal: .opacity
            ))
            detailStrip
        }
        .padding(AppStyle.Spacing.medium)
        .overviewCard()
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: currentLevel.id)
        .onChange(of: openGroup) { _ in hoveredID = nil }
    }

    // MARK: Levels

    private var currentLevel: EverythingElseMapLevel {
        if let openGroup, let figures = breakdown[openGroup] {
            return .folders(figures, steamGames: store.everythingElseMeasurement?.steamGames ?? [:])
        }
        return .groups(breakdown)
    }

    private var selectedID: String? {
        if openGroup != nil { return selectedFolderPath }
        return nil
    }

    private func select(_ tile: EverythingElseMapTile?) {
        guard let tile else {
            if openGroup != nil { selectedFolderPath = nil }
            return
        }
        switch tile.kind {
        case .folder(let folder):
            selectedFolderPath = folder.path
        case .group, .macOS, .notMeasured, .smaller, .lockedGroup:
            break
        }
    }

    /// Double-click or Return on a group tile: zoom in on it.
    private func open(_ tile: EverythingElseMapTile, anchor: UnitPoint) {
        switch tile.kind {
        case .group(let group), .lockedGroup(let group):
            zoomAnchor = anchor
            openGroup = group
            selectedFolderPath = nil
        case .folder, .macOS, .notMeasured, .smaller:
            break
        }
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: AppStyle.Spacing.xxSmall) {
            crumb(String(localized: "Everything else"), isCurrent: openGroup == nil) {
                zoomAnchor = .center
                openGroup = nil
            }
            if let openGroup {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                crumb(EverythingElseStyle.name(openGroup), isCurrent: true) {}
            }
            Spacer()
            Text(openGroup == nil ? "Double-click a group to open it" : "Click Everything else in the crumb to go back")
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textTertiary)
        }
        .accessibilityElement(children: .contain)
    }

    private func crumb(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppStyle.Typography.headline)
                .foregroundStyle(isCurrent ? AppColors.textPrimary : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityAddTraits(isCurrent ? [.isHeader] : [])
    }

    // MARK: Detail strip

    /// The tile under the pointer, or the selected one: name, path, size, share,
    /// and the same actions the list row has.
    @ViewBuilder
    private var detailStrip: some View {
        let level = currentLevel
        let tile = level.tiles.first { $0.id == hoveredID } ?? level.tiles.first { $0.id == selectedID }
        HStack(spacing: AppStyle.Spacing.small) {
            if let tile {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppStyle.Spacing.xSmall) {
                        Text(tile.name)
                            .font(AppStyle.Typography.rowTitle)
                            .lineLimit(1)
                        if let pill = tile.pill {
                            AppBadge(text: pill.text, tone: pill.tone)
                        }
                    }
                    Text(tile.subtitle)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AppStyle.Spacing.small)
                Text("\(OverviewCategoryStyle.shareText(level.share(of: tile.bytes))) · \(formatStorageBytes(tile.bytes))")
                    .font(AppStyle.Typography.headline)
                    .monospacedDigit()
                switch tile.kind {
                case .folder(let folder):
                    Button("Show in Finder") { FinderReveal.show(folder.url) }
                        .buttonStyle(.purge(.quiet, size: .small))
                    if let action = store.everythingElseFolderHint(for: folder)?.action {
                        Button(Self.actionTitle(action)) { store.performEverythingElseHint(action) }
                            .buttonStyle(.purge(.secondary, size: .small))
                    }
                case .group(let group), .lockedGroup(let group):
                    Button("Open") { open(tile, anchor: .center) }
                        .buttonStyle(.purge(.quiet, size: .small))
                        .accessibilityLabel("Open \(EverythingElseStyle.name(group))")
                case .macOS, .notMeasured, .smaller:
                    EmptyView()
                }
            } else {
                Text(openGroup == nil ? "Hover a tile for its size and share. Tiles under 3 points are not drawn." : "Hover a folder for its path and size.")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer()
            }
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .contain)
    }

    static func actionTitle(_ action: EverythingElseFolderHint.Action) -> String {
        switch action {
        case .openApp(_, let title): return title
        case .openURL(_, let title): return title
        case .showInLargeFiles: return String(localized: "Show in Large Files")
        }
    }
}

// MARK: - Level model

/// What one tile stands for.
struct EverythingElseMapTile: Identifiable, Equatable {
    enum Kind: Equatable {
        case group(EverythingElseGroup)
        /// A group a limited scan could not read. Still a tile, so the lock shows.
        case lockedGroup(EverythingElseGroup)
        case folder(EverythingElseFolder)
        case macOS
        case notMeasured
        /// Everything under the floor on a group level.
        case smaller(count: Int)
    }

    struct Pill: Equatable {
        let text: String
        let tone: AppBadge.Tone
    }

    let id: String
    let kind: Kind
    let name: String
    let subtitle: String
    let bytes: Int64
    let fill: Color
    let label: Color
    /// Purge's meaning on the tile, in colour: never the fill, always a pill.
    let pill: Pill?

    static func == (lhs: EverythingElseMapTile, rhs: EverythingElseMapTile) -> Bool {
        lhs.id == rhs.id && lhs.bytes == rhs.bytes && lhs.name == rhs.name && lhs.pill == rhs.pill
    }
}

/// One level of the map: the tiles, their total, and the floor under which the
/// smaller tile gathers things.
struct EverythingElseMapLevel {
    let id: String
    let tiles: [EverythingElseMapTile]
    let totalBytes: Int64
    let floorBytes: Int64

    var items: [TreemapItem] {
        tiles.map { TreemapItem(id: $0.id, weight: Double($0.bytes)) }
    }

    func share(of bytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    func tile(for id: String) -> EverythingElseMapTile? {
        tiles.first { $0.id == id }
    }

    /// The groups, biggest first, with macOS and the remainder so it adds up.
    /// No floor: a small group still gets its tile, or is cut at 3 points.
    static func groups(_ breakdown: EverythingElseBreakdown) -> EverythingElseMapLevel {
        var tiles: [EverythingElseMapTile] = []
        for group in breakdown.measuredGroupsBySize {
            let figures = breakdown[group]
            let bytes = breakdown.bytes(for: group)
            let locked = figures?.isLocked == true
            guard bytes > 0 || locked else { continue }
            tiles.append(EverythingElseMapTile(
                id: EverythingElseStyle.segmentID(group),
                kind: locked && bytes == 0 ? .lockedGroup(group) : .group(group),
                name: EverythingElseStyle.name(group),
                subtitle: EverythingElseStyle.detail(group),
                bytes: bytes,
                fill: EverythingElseStyle.color(group),
                label: EverythingElseStyle.labelColor(group),
                pill: locked ? Pill(text: String(localized: "Needs Full Disk Access"), tone: .warning) : nil
            ))
        }
        for group in [EverythingElseGroup.macOS, .notMeasured] where breakdown.bytes(for: group) > 0 {
            tiles.append(EverythingElseMapTile(
                id: EverythingElseStyle.segmentID(group),
                kind: group == .macOS ? .macOS : .notMeasured,
                name: EverythingElseStyle.name(group),
                subtitle: EverythingElseStyle.detail(group),
                bytes: breakdown.bytes(for: group),
                fill: EverythingElseStyle.color(group),
                label: EverythingElseStyle.labelColor(group),
                pill: nil
            ))
        }
        return EverythingElseMapLevel(id: "groups", tiles: tiles, totalBytes: breakdown.everythingElseBytes, floorBytes: 0)
    }

    /// A group's folders over the floor, one step lighter than the group, plus
    /// the smaller tile in the group's own shade.
    static func folders(_ figures: EverythingElseGroupBreakdown, steamGames: [String: SteamGame]) -> EverythingElseMapLevel {
        let group = figures.group
        let shade = EverythingElseStyle.color(group)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var tiles = figures.folders.map { folder -> EverythingElseMapTile in
            let hint = EverythingElseFolderHint.hint(for: folder.path, group: group, home: home, steamGames: steamGames)
            let pill: Pill?
            switch hint?.action {
            case .showInLargeFiles: pill = Pill(text: String(localized: "In Large Files"), tone: .safe)
            case .openApp, .openURL: pill = Pill(text: String(localized: "Has its own uninstall"), tone: .accent)
            case nil: pill = nil
            }
            return EverythingElseMapTile(
                id: folder.path,
                kind: .folder(folder),
                name: folder.name,
                subtitle: displayDirectoryPath(for: folder.url),
                bytes: folder.bytes,
                // A step lighter than the group: depth is lightness, not hue.
                fill: shade.opacity(0.62),
                label: AppColors.textPrimary,
                pill: pill
            )
        }
        if figures.smallerFolderCount > 0 || figures.smallerBytes > 0 {
            tiles.append(EverythingElseMapTile(
                id: TreemapPlan.smallerID,
                kind: .smaller(count: figures.smallerFolderCount),
                name: EverythingElseStyle.smallerLine(count: figures.smallerFolderCount, bytes: figures.smallerBytes),
                subtitle: String(localized: "Under \(formatStorageBytes(EverythingElseBreakdown.defaultFloorBytes)) each, with any loose files"),
                bytes: figures.smallerBytes,
                fill: shade,
                label: EverythingElseStyle.labelColor(group),
                pill: nil
            ))
        }
        return EverythingElseMapLevel(id: "group.\(group.rawValue)", tiles: tiles, totalBytes: figures.bytes, floorBytes: 0)
    }

    private typealias Pill = EverythingElseMapTile.Pill
}

// MARK: - Canvas

/// The tiles of one level, drawn by hand. Labels only where they fit; a frame
/// around the group's tiles; the selected tile outlined; the hovered one lifted.
private struct EverythingElseTreemap: View {
    let level: EverythingElseMapLevel
    let plan: TreemapPlan
    @Binding var hoveredID: String?
    let selectedID: String?
    let onSelect: (EverythingElseMapTile?) -> Void
    let onOpen: (EverythingElseMapTile, UnitPoint) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 2
    private static let labelInset: CGFloat = 6
    private static let minimumLabelWidth: CGFloat = 56
    private static let minimumLabelHeight: CGFloat = 30
    private static let pillHeight: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(AppColors.fillSecondary))
            for tile in plan.tiles {
                guard let model = level.tile(for: tile.id) else { continue }
                draw(model, in: tile.rect.insetBy(dx: Self.gap / 2, dy: Self.gap / 2), context: &context)
            }
            // The level's frame, so the tiles read as one group rather than a flat field.
            context.stroke(
                Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: AppStyle.Radius.md),
                with: .color(AppColors.borderStrong),
                lineWidth: 1
            )
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let id = tile(at: location)?.id
                if id != hoveredID { hoveredID = id }
            case .ended:
                hoveredID = nil
            }
        }
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
            guard let tile = tile(at: location), let model = level.tile(for: tile.id) else { return }
            onOpen(model, anchor(of: tile))
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { location in
            onSelect(tile(at: location).flatMap { level.tile(for: $0.id) })
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hoveredID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Map"))
        .accessibilityChildren {
            ForEach(plan.tiles) { tile in
                if let model = level.tile(for: tile.id) {
                    Color.clear
                        .accessibilityLabel(accessibilityText(model))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(selectedID == tile.id ? [.isSelected] : [])
                        .accessibilityAction { onSelect(model) }
                        .accessibilityAction(named: Text("Open")) { onOpen(model, .center) }
                }
            }
        }
    }

    private func accessibilityText(_ model: EverythingElseMapTile) -> String {
        var text = String(localized: "\(model.name), \(formatStorageBytes(model.bytes)), \(OverviewCategoryStyle.shareText(level.share(of: model.bytes)))")
        if let pill = model.pill { text += ", " + pill.text }
        return text
    }

    private func tile(at point: CGPoint) -> TreemapTile? {
        plan.tiles.first { $0.rect.contains(point) }
    }

    private func anchor(of tile: TreemapTile) -> UnitPoint {
        let bounds = plan.tiles.reduce(CGRect.null) { $0.union($1.rect) }
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        return UnitPoint(x: tile.rect.midX / bounds.width, y: tile.rect.midY / bounds.height)
    }

    private func draw(_ model: EverythingElseMapTile, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let isHovered = hoveredID == model.id
        let isSelected = selectedID == model.id
        let shape = Path(roundedRect: rect, cornerRadius: AppStyle.Radius.xs)
        context.fill(shape, with: .color(model.fill))
        if isHovered {
            context.fill(shape, with: .color(AppColors.textPrimary.opacity(0.08)))
        }
        if isSelected {
            context.stroke(shape, with: .color(AppColors.actionPrimary), lineWidth: 2)
        }

        // Labels only where they fit: name, then size under it, then the pill.
        let inner = rect.insetBy(dx: Self.labelInset, dy: Self.labelInset)
        guard inner.width >= Self.minimumLabelWidth, inner.height >= Self.minimumLabelHeight else { return }
        var cursorY = inner.minY
        let name = context.resolve(Text(model.name).font(AppStyle.Typography.rowTitle).foregroundColor(model.label))
        let nameSize = name.measure(in: CGSize(width: inner.width, height: inner.height))
        if nameSize.height <= inner.height {
            context.draw(name, in: CGRect(x: inner.minX, y: cursorY, width: inner.width, height: nameSize.height))
            cursorY += nameSize.height + 1
        }
        let size = context.resolve(Text(formatStorageBytes(model.bytes)).font(AppStyle.Typography.metadata).foregroundColor(model.label.opacity(0.8)))
        let sizeSize = size.measure(in: CGSize(width: inner.width, height: inner.height))
        if cursorY + sizeSize.height <= inner.maxY {
            context.draw(size, in: CGRect(x: inner.minX, y: cursorY, width: inner.width, height: sizeSize.height))
            cursorY += sizeSize.height + 3
        }
        if let pill = model.pill, cursorY + Self.pillHeight <= inner.maxY {
            let text = context.resolve(Text(pill.text).font(AppStyle.Typography.micro).foregroundColor(Self.pillText(pill.tone)))
            let textSize = text.measure(in: CGSize(width: inner.width - 10, height: Self.pillHeight))
            guard textSize.width + 10 <= inner.width else { return }
            let pillRect = CGRect(x: inner.minX, y: cursorY, width: textSize.width + 10, height: Self.pillHeight)
            context.fill(Path(roundedRect: pillRect, cornerRadius: AppStyle.Radius.xs), with: .color(Self.pillFill(pill.tone)))
            context.draw(text, in: pillRect.insetBy(dx: 5, dy: (Self.pillHeight - textSize.height) / 2))
        }
    }

    private static func pillFill(_ tone: AppBadge.Tone) -> Color {
        switch tone {
        case .safe: return AppColors.statusSafeFill
        case .warning: return AppColors.statusCheckFill
        case .danger: return AppColors.statusDangerFill
        case .neutral, .accent: return AppColors.statusUnsureFill
        }
    }

    private static func pillText(_ tone: AppBadge.Tone) -> Color {
        switch tone {
        case .safe: return AppColors.statusSafeText
        case .warning: return AppColors.statusCheckText
        case .danger: return AppColors.statusDangerText
        case .neutral, .accent: return AppColors.statusUnsureText
        }
    }
}
