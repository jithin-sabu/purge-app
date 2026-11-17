import AppKit
import SwiftUI

enum DeveloperFindingReview: String, Identifiable {
    case attention, caches
    var id: String { rawValue }
}

/// Owns presentation state locally so opening a review does not rebuild and
/// reposition the enclosing scan results List.
struct DeveloperScanFindingLinks: View {
    @EnvironmentObject private var store: PurgeStore
    @State private var review: DeveloperFindingReview?

    var body: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            if !store.deepScanIssues.isEmpty {
                Button { review = .attention } label: {
                    HStack {
                        Text("Folders needing attention (\(store.deepScanIssues.count))")
                        Spacer()
                        Text("Review")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.purge(.secondary, width: .fill))
            }
            if !store.deepScanUnknownCaches.isEmpty {
                Button { review = .caches } label: {
                    HStack {
                        Text("Other cache folders to inspect (\(store.deepScanUnknownCaches.count))")
                        Spacer()
                        Text("Review")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.purge(.secondary, width: .fill))
            }
        }
        .padding(.vertical, AppStyle.Spacing.small)
        .sheet(item: $review) { choice in
            DeveloperScanFindingsSheet(review: choice)
                .environmentObject(store)
        }
    }
}

struct DeveloperScanFindingsSheet: View {
    let review: DeveloperFindingReview
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch review {
        case .attention: return String(localized: "Folders needing attention (\(store.deepScanIssues.count))")
        case .caches: return String(localized: "Other cache folders to inspect (\(store.deepScanUnknownCaches.count))")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            Text(title).font(AppStyle.Typography.sectionTitle)
            if review == .attention {
                Text("See why each folder wasn't fully scanned. You can inspect it in Finder or scan a deep branch directly.")
                    .font(AppStyle.Typography.callout).foregroundStyle(AppColors.textSecondary)
            } else {
                Text("These folders use disk space, but Purge hasn't identified them as rebuildable caches. Inspect them before deciding what to keep.")
                    .font(AppStyle.Typography.callout).foregroundStyle(AppColors.textSecondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: review == .caches ? AppStyle.Spacing.xSmall : AppStyle.Spacing.medium) {
                    if review == .attention {
                        ForEach(store.deepScanIssues) { issue in
                            InsetCard {
                                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                                    folderIdentity(issue.url)
                                    Text(issue.explanation)
                                        .font(AppStyle.Typography.callout).foregroundStyle(AppColors.textSecondary)
                                    HStack(spacing: AppStyle.Spacing.small) {
                                        folderActions(issue.url)
                                        if issue.canScanFromHere {
                                            Button("Scan from here") {
                                                store.addDeveloperCleaningRoots([issue.url])
                                                store.requestScan(.cachesAndDevTools)
                                                dismiss()
                                            }
                                            .buttonStyle(.purge(.secondary, size: .small))
                                            .disabled(store.isDeepScanning || store.isScanningAll || store.isDeleting)
                                        }
                                    }
                                }
                                .padding(AppStyle.Spacing.medium)
                            }
                        }
                    } else {
                        ForEach(store.deepScanUnknownCaches) { folder in
                            InsetCard {
                                HStack(spacing: AppStyle.Spacing.small) {
                                    VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                                        Text(folder.url.lastPathComponent)
                                            .font(AppStyle.Typography.rowTitle)
                                            .lineLimit(1)
                                        Text(folder.url.path)
                                            .font(AppStyle.Typography.metadata)
                                            .foregroundStyle(AppColors.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                            .help(folder.url.path)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(formatBytes(folder.sizeBytes))
                                        .font(AppStyle.Typography.rowTitle.numbers)
                                        .monospacedDigit()
                                        .fixedSize()
                                    HStack(spacing: AppStyle.Spacing.xSmall) {
                                        Button { FinderReveal.show(folder.url) } label: {
                                            Label("Show in Finder", systemImage: "folder")
                                                .labelStyle(.iconOnly)
                                        }
                                        .help("Show in Finder")
                                        Button { FinderReveal.copyPaths([folder.url]) } label: {
                                            Label("Copy Path", systemImage: "doc.on.doc")
                                                .labelStyle(.iconOnly)
                                        }
                                        .help("Copy Path")
                                    }
                                    .buttonStyle(.purge(.secondary, size: .small))
                                }
                                .padding(.horizontal, AppStyle.Spacing.small)
                                .padding(.vertical, AppStyle.Spacing.xSmall)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.purge(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 640, height: 520)
        .background(AppColors.surfaceBase)
    }

    private func folderIdentity(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
            Text(url.lastPathComponent).font(AppStyle.Typography.rowTitle)
            Text(url.path).font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderActions(_ url: URL) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Button("Show in Finder") { FinderReveal.show(url) }
                .buttonStyle(.purge(.secondary, size: .small))
            Button("Copy Path") { FinderReveal.copyPaths([url]) }
                .buttonStyle(.purge(.secondary, size: .small))
        }
    }
}
