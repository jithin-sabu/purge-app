import AppKit
import Photos
import SwiftUI

struct PhotosLibraryView: View {
    @ObservedObject var model: PhotosLibraryStore
    var isLifecycleActive = true
    var usesLiveLibrary = !TestHost.isActive()
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: PhotosLibraryItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                notice
                if model.access.canRead {
                    review
                } else {
                    permission
                }
                if let message = model.message {
                    Text(verbatim: message)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                }
                if let count = model.removedCount {
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                        Text(String(localized: "Moved to Recently Deleted: \(count)"))
                            .font(AppStyle.Typography.headline)
                        Text(String(localized: "Recover these items in Photos within 30 days, unless you permanently delete them sooner. No disk space is claimed as freed."))
                            .font(AppStyle.Typography.callout)
                    }
                    .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(AppStyle.Spacing.large)
        }
        .underDetailPageHeader(includesSubtitle: true)
        .task {
            guard isLifecycleActive, usesLiveLibrary else { return }
            await model.open()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, isLifecycleActive, usesLiveLibrary else { return }
            Task { await model.open() }
        }
        .onDisappear { model.leave() }
        .sheet(item: $model.pendingRemoval) { plan in
            PhotosRemovalSheet(plan: plan, onCancel: { model.pendingRemoval = nil }) {
                Task { await model.confirmRemoval(plan) }
            }
            .interactiveDismissDisabled(model.isRemoving)
        }
        .sheet(item: $preview) { item in
            VStack(spacing: AppStyle.Spacing.medium) {
                PhotosThumbnail(id: item.id, kind: item.metadata.kind, usesLiveLibrary: usesLiveLibrary, isPreview: true)
                Text(verbatim: item.metadata.filename).font(AppStyle.Typography.rowTitle)
                Button(String(localized: "Done")) { preview = nil }.buttonStyle(.purge(.secondary))
            }
            .padding(AppStyle.Spacing.large)
        }
    }

    private var notice: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(String(localized: "Review your Photos library"))
                    .font(AppStyle.Typography.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Text(String(localized: "Nothing is selected automatically. Removed items go to Recently Deleted in Photos for 30 days, unless permanently deleted sooner. With iCloud Photos, removal syncs to every device using the same library."))
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(AppStyle.Spacing.medium)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text(String(localized: "Photos access"))
                .font(AppStyle.Typography.sectionTitle)
            Text(String(localized: "Purge needs Photos access to review library items and remove only the ones you select. It never edits the library's files directly."))
                .font(AppStyle.Typography.body)
                .foregroundStyle(AppColors.textSecondary)
            if model.access == .restricted {
                Text(String(localized: "Photos access is restricted on this Mac."))
                    .font(AppStyle.Typography.callout)
            } else if model.access == .denied {
                Button(String(localized: "Open Photos Permissions")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.purge(.secondary))
            } else {
                Button(String(localized: "Allow Photos Access")) { Task { await model.open() } }
                    .buttonStyle(.purge(.primary))
            }
        }
        .foregroundStyle(AppColors.textPrimary)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Picker(String(localized: "Show"), selection: $model.category) {
                ForEach(PhotosCategory.allCases) { category in
                    Text(verbatim: category.title).tag(category)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isRemoving || model.pendingRemoval != nil)

            if model.access == .limited {
                Text(String(localized: "Only items allowed by your Photos permission are shown."))
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Text(verbatim: categoryExplanation)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)

            if model.isScanning {
                HStack(spacing: AppStyle.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Reading Photos metadata and measuring local videos…"))
                        .font(AppStyle.Typography.body)
                }
            } else if model.isRemoving {
                ProgressView(String(localized: "Waiting for Photos…"))
                    .font(AppStyle.Typography.body)
            } else if model.visibleItems.isEmpty {
                Text(model.hasScanned ? String(localized: "No items in this category.") : String(localized: "Refresh to read the Photos library."))
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.vertical, AppStyle.Spacing.large)
            } else {
                let keepers = model.snapshot.burstKeepers
                let burstIDs = Set(model.visibleItems.compactMap { $0.metadata.burstID }).sorted()
                let burstNumbers = Dictionary(uniqueKeysWithValues: burstIDs.enumerated().map { ($0.element, $0.offset + 1) })
                LazyVStack(spacing: AppStyle.Spacing.xSmall) {
                    ForEach(model.visibleItems) { item in
                        PhotosLibraryRow(
                            item: item,
                            isKeeper: keepers.contains(item.id),
                            canSelect: PhotosLibrarySnapshot.canRemove(item.metadata, keepers: keepers),
                            burstNumber: item.metadata.burstID.flatMap { burstNumbers[$0] },
                            selected: Binding(
                                get: { model.selectedIDs.contains(item.id) },
                                set: { model.select(item, selected: $0) }
                            ),
                            usesLiveLibrary: usesLiveLibrary,
                            onPreview: { preview = item }
                        )
                    }
                }
            }
        }
    }

    private var categoryExplanation: String {
        switch model.category {
        case .videos, .screenRecordings:
            String(localized: "Largest original videos first; unknown sizes last. iCloud originals are never downloaded. Original size is not space freed on this Mac.")
        case .bursts:
            String(localized: "Members are grouped by burst. Photos' picks and the representative are kept. If no pick is available, Purge keeps one member.")
        case .rawPairs:
            String(localized: "Review only. PhotoKit cannot remove just the RAW or JPEG resource. Purge keeps both originals and never offers the pair for deletion.")
        case .screenshots:
            String(localized: "Review screenshots before selecting them. Each selection removes the whole Photos item, including any edits.")
        }
    }
}

struct PhotosHeaderActions: View {
    @ObservedObject var model: PhotosLibraryStore

    var body: some View {
        if model.access.canRead {
            ViewThatFits(in: .horizontal) {
                buttons(showsTitles: true)
                buttons(showsTitles: false)
            }
        }
    }

    private func buttons(showsTitles: Bool) -> some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button {
                if model.isScanning { model.stop() } else { model.refresh() }
            } label: {
                actionLabel(model.isScanning ? String(localized: "Stop") : String(localized: "Refresh"),
                            icon: model.isScanning ? "stop.fill" : "arrow.clockwise", showsTitle: showsTitles)
            }
            .buttonStyle(.purge(.secondary))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRemoving || model.pendingRemoval != nil)
            .help(model.isScanning ? String(localized: "Stop") : String(localized: "Refresh"))

            Button { model.requestRemoval() } label: {
                actionLabel(String(localized: "Remove Selected"), icon: "trash", showsTitle: showsTitles)
            }
            .buttonStyle(.purge(.primary))
            .disabled(model.selectedIDs.isEmpty || model.isScanning || model.isRemoving)
            .help(String(localized: "Remove Selected"))
        }
        .fixedSize()
    }

    @ViewBuilder
    private func actionLabel(_ title: String, icon: String, showsTitle: Bool) -> some View {
        if showsTitle { Label(title, systemImage: icon) }
        else { Label(title, systemImage: icon).labelStyle(.iconOnly) }
    }
}

private struct PhotosLibraryRow: View {
    let item: PhotosLibraryItem
    let isKeeper: Bool
    let canSelect: Bool
    let burstNumber: Int?
    @Binding var selected: Bool
    let usesLiveLibrary: Bool
    let onPreview: () -> Void

    var body: some View {
        InsetCard {
            HStack(spacing: AppStyle.Spacing.small) {
                Toggle(isOn: $selected) { Text(verbatim: item.metadata.filename) }
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!canSelect)
                    .accessibilityLabel(Text(verbatim: item.metadata.filename))
                Button(action: onPreview) {
                    PhotosThumbnail(id: item.id, kind: item.metadata.kind, usesLiveLibrary: usesLiveLibrary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Preview Photos item"))
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    Text(verbatim: item.metadata.filename)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                    if let date = item.metadata.created {
                        Text(date, format: .dateTime.year().month().day())
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let burstNumber {
                        Text(String(localized: "Burst \(burstNumber)"))
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textTertiary)
                            .lineLimit(1)
                    }
                    if item.metadata.isFavorite {
                        Label(String(localized: "Favorite"), systemImage: "heart.fill")
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer(minLength: AppStyle.Spacing.xSmall)
                VStack(alignment: .trailing, spacing: AppStyle.Spacing.xxSmall) {
                    if item.metadata.kind == .video {
                        Text(item.originalBytes.map(formatStorageBytes) ?? String(localized: "Size unavailable"))
                            .font(AppStyle.Typography.metadata.numbers)
                        Text(Duration.seconds(item.metadata.duration), format: .time(pattern: .minuteSecond))
                            .font(AppStyle.Typography.metadata.numbers)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if isKeeper {
                        Text(item.metadata.isBurstPick || item.metadata.isBurstRepresentative
                             ? String(localized: "Keeping burst pick") : String(localized: "Keeping burst member"))
                            .font(AppStyle.Typography.micro)
                            .foregroundStyle(AppColors.textSecondary)
                    } else if !canSelect {
                        Text(String(localized: "Review only"))
                            .font(AppStyle.Typography.micro)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .padding(AppStyle.Spacing.small)
        }
        .foregroundStyle(AppColors.textPrimary)
    }
}

/// Local-only thumbnails. Tests supply placeholders and never fetch library assets.
private struct PhotosThumbnail: View {
    let id: String
    let kind: PhotosAssetMetadata.Kind
    let usesLiveLibrary: Bool
    var isPreview = false
    @State private var thumbnail: NSImage?
    @State private var requestID: PHImageRequestID?

    private enum Layout {
        static let thumbnail: CGFloat = 64
        static let preview: CGFloat = 480
        static let requestPixels: CGFloat = 960
    }

    var body: some View {
        ZStack {
            AppColors.fillSecondary
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: kind == .video ? "video" : "photo")
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .frame(width: isPreview ? Layout.preview : Layout.thumbnail, height: isPreview ? Layout.preview : Layout.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm))
        .onAppear {
            guard usesLiveLibrary, !TestHost.isActive(), PhotoKitLibrary.access().canRead,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: Layout.requestPixels, height: Layout.requestPixels),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                Task { @MainActor in thumbnail = image }
            }
        }
        .onDisappear {
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil
            thumbnail = nil
        }
        .accessibilityLabel(String(localized: "Photos preview; cloud-only thumbnails may be unavailable"))
    }
}

struct PhotosRemovalSheet: View {
    let plan: PhotosRemovalPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private enum Layout { static let width: CGFloat = 520; static let listHeight: CGFloat = 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            Text(String(localized: "Remove from Photos?"))
                .font(AppStyle.Typography.sectionTitle)
            Text(String(localized: "Selected Photos items: \(plan.assets.count)"))
                .font(AppStyle.Typography.body)
            Text(String(localized: "This removes the whole item, including its edits. With iCloud Photos, removal syncs to every device using the same library."))
                .font(AppStyle.Typography.body)
            Text(String(localized: "Items go to Recently Deleted in Photos and can be recovered for 30 days, unless permanently deleted sooner. Storage may not be freed until they are permanently removed."))
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                    ForEach(plan.assets) { item in
                        Text(verbatim: item.filename).font(AppStyle.Typography.rowTitle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: Layout.listHeight)
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Move to Recently Deleted"), action: onConfirm)
                    .buttonStyle(.purge(.destructive))
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        .padding(AppStyle.Spacing.large)
        .frame(width: Layout.width)
        .background(AppColors.surfaceBase)
    }
}
