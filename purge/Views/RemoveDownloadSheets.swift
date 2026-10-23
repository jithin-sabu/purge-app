import AppKit
import SwiftUI

/// Confirms Remove Download for iCloud files picked in Large Files (#106).
///
/// The point of the copy is that nothing disappears: the files stay in iCloud
/// and in their folders, marked with a cloud, and only the copy on this Mac
/// goes. It also says the one real cost, that opening them needs a connection.
struct RemoveDownloadConfirmSheet: View {
    let request: RemoveDownloadRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var files: [LargeFile] {
        request.files.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var totalBytes: Int64 {
        request.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var title: String {
        request.files.count == 1
            ? String(localized: "Remove this download from your Mac?")
            : String(localized: "Remove these downloads from your Mac?")
    }

    private var explanation: String {
        request.files.count == 1
            ? String(localized: "The file stays in iCloud Drive and in its folder in Finder, marked with a cloud. Purge removes only the copy on this Mac. Open the file to download it again. You need an internet connection to open it.")
            : String(localized: "The files stay in iCloud Drive and in their folders in Finder, marked with a cloud. Purge removes only the copies on this Mac. Open a file to download it again. You need an internet connection to open them.")
    }

    private var confirmTitle: String {
        request.files.count == 1
            ? String(localized: "Remove Download")
            : String(localized: "Remove \(request.files.count) Downloads")
    }

    private var leftOutNote: String? {
        switch request.leftOutCount {
        case 0:
            return nil
        case 1:
            return String(localized: "1 other selected file syncs with iCloud but can't have its download removed yet, for example because it's still uploading. Purge leaves it as it is.")
        default:
            return String(localized: "\(request.leftOutCount) other selected files sync with iCloud but can't have their downloads removed yet, for example because they're still uploading. Purge leaves them as they are.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(explanation)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(spacing: AppStyle.Spacing.small) {
                    ForEach(files) { file in
                        RemoveDownloadFileCard(
                            name: file.displayName,
                            location: file.locationLabel,
                            size: file.formattedSize
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180)

            if let leftOutNote {
                LargeFileCautionNote { Text(leftOutNote) }
            }

            HStack(spacing: AppStyle.Spacing.small) {
                Text("Freeing \(formatBytes(totalBytes)) on this Mac")
                    .font(AppStyle.Typography.metadataEmphasis.numbers)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)

                // Primary, not destructive: nothing is deleted.
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 580, minHeight: 420)
        .background(AppColors.surfaceBase)
    }
}

/// What a Remove Download did. The removed rows have just left the list, so
/// this is where the user learns where the files are: still in iCloud Drive,
/// still in their folders, one click away in Finder.
struct RemoveDownloadResultSheet: View {
    let report: ICloudDownloadReport
    let onDone: () -> Void

    private var title: String {
        switch report.removed.count {
        case 0: return String(localized: "No downloads removed")
        case 1: return String(localized: "Download removed")
        default: return String(localized: "\(report.removed.count) downloads removed")
        }
    }

    private var explanation: String {
        switch report.removed.count {
        case 0:
            return String(localized: "Nothing changed. The files below are still downloaded on this Mac.")
        case 1:
            return String(localized: "Freed \(formatBytes(report.bytesFreed)) on this Mac. The file is still in iCloud Drive and in its folder in Finder. Open it to download it again.")
        default:
            return String(localized: "Freed \(formatBytes(report.bytesFreed)) on this Mac. The files are still in iCloud Drive and in their folders in Finder. Open one to download it again.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(explanation)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    ForEach(report.removed, id: \.path) { item in
                        let url = URL(fileURLWithPath: item.path)
                        RemoveDownloadFileCard(
                            name: url.lastPathComponent,
                            location: Self.location(of: url),
                            size: formatBytes(item.bytesFreed),
                            showsCloud: true
                        )
                    }

                    if !report.skipped.isEmpty {
                        Text("Left on this Mac")
                            .font(AppStyle.Typography.metadata.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .textCase(.uppercase)
                            .padding(.top, AppStyle.Spacing.xSmall)

                        ForEach(report.skipped, id: \.path) { item in
                            let url = URL(fileURLWithPath: item.path)
                            RemoveDownloadFileCard(
                                name: url.lastPathComponent,
                                location: Self.location(of: url),
                                detail: item.localizedReason
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180)

            HStack(spacing: AppStyle.Spacing.small) {
                Spacer()

                if !report.removed.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            report.removed.map { URL(fileURLWithPath: $0.path) }
                        )
                    }
                    .buttonStyle(.purge(.secondary))
                }

                Button("Done", action: onDone)
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 560, minHeight: 360)
        .background(AppColors.surfaceBase)
    }

    static func location(of file: URL) -> String {
        let folder = file.deletingLastPathComponent()
        return LargeFile.iCloudDriveLocation(for: folder) ?? displayDirectoryPath(for: folder)
    }
}

/// One file on the Remove Download sheets, styled like the trash sheet's cards.
private struct RemoveDownloadFileCard: View {
    let name: String
    let location: String
    var size: String?
    var detail: String?
    /// The cloud mark after the location, for a file that is now cloud-only.
    var showsCloud = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: "doc")
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(location)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if showsCloud {
                        Image(systemName: "icloud")
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                            .accessibilityLabel("In iCloud Drive")
                    }
                }

                if let detail {
                    Text(detail)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            if let size {
                Text(size)
                    .font(AppStyle.Typography.metadataEmphasis.numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(AppColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
