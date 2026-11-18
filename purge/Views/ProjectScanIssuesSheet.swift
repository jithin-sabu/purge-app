import SwiftUI

struct ProjectScanIssuesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [ProjectScanIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            Text("Folders needing attention (\(issues.count))")
                .font(AppStyle.Typography.sectionTitle)
            ScrollView {
                LazyVStack(spacing: AppStyle.Spacing.xSmall) {
                    ForEach(issues) { issue in
                        InsetCard {
                            HStack(spacing: AppStyle.Spacing.small) {
                                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                                    Text(issue.path)
                                        .font(AppStyle.Typography.rowTitle)
                                        .textSelection(.enabled)
                                    Text(issue.explanation)
                                        .font(AppStyle.Typography.metadata)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Copy Path") { FinderReveal.copyPaths([issue.url]) }
                                    .buttonStyle(.purge(.secondary, size: .small))
                            }
                            .padding(AppStyle.Spacing.small)
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
        .frame(width: 640, height: 440)
        .background(AppColors.surfaceBase)
    }
}
