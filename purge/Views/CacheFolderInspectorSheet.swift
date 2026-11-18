import SwiftUI

/// The inspector runs when opened, independently of any project scan.
struct CacheFolderInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var result: CacheFolderInspector.Result?

    let root: URL
    let knownPaths: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            Text("Other cache folders to inspect")
                .font(AppStyle.Typography.sectionTitle)
            Text("Review these folders in Finder before deciding what to keep.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
            switch result {
            case nil:
                ProgressView("Measuring cache folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                Text("Purge couldn't read ~/.cache.").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .folders(let folders):
                if folders.isEmpty {
                    Text("No other cache folders found.").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: AppStyle.Spacing.xSmall) {
                            ForEach(folders, content: row)
                        }
                    }
                }
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
        .task {
            let task = Task.detached(priority: .utility) {
                CacheFolderInspector.inspect(at: root, knownPaths: knownPaths)
            }
            let inspected = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if !Task.isCancelled { result = inspected }
        }
    }

    private func row(_ folder: CacheFolderInspector.Folder) -> some View {
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
                Text(folder.bytes.map(formatBytes) ?? String(localized: "Size unavailable"))
                    .font(AppStyle.Typography.rowTitle.numbers)
                    .monospacedDigit()
                    .fixedSize()
                HStack(spacing: AppStyle.Spacing.xSmall) {
                    Button { FinderReveal.show(folder.url) } label: {
                        Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }
                    .help("Show in Finder")
                    Button { FinderReveal.copyPaths([folder.url]) } label: {
                        Label("Copy Path", systemImage: "doc.on.doc").labelStyle(.iconOnly)
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
