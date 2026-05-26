import SwiftUI

struct ScanStatusBar: View {
    let isLoading: Bool
    let visibleCount: Int
    let totalCount: Int
    let isFiltered: Bool
    let visibleBytes: Int64
    let totalBytes: Int64
    let selectedCount: Int
    let selectedBytes: Int64

    private var displayedBytes: Int64 {
        isFiltered ? visibleBytes : totalBytes
    }

    private var itemCountLabel: String {
        if isFiltered {
            return "\(visibleCount) of \(totalCount) items"
        }
        return "\(totalCount) items"
    }

    var body: some View {
        if isLoading && totalCount == 0 {
            ScanStatusBarSkeleton(showsSelectedSummary: selectedCount > 0)
        } else {
            loadedStatusBar
        }
    }

    private var loadedStatusBar: some View {
        HStack(spacing: 8) {
            Text(itemCountLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if selectedCount > 0 {
                separator
                Text("\(selectedCount) selected")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 12)

            if selectedCount > 0 {
                Text("\(formatBytes(selectedBytes)) selected")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                separator
            }

            Text("\(formatBytes(displayedBytes)) total")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(AppStyle.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppStyle.hairline)
                .frame(height: 1)
        }
    }

    private var separator: some View {
        Text("·")
            .monospaced(false)
            .foregroundStyle(.tertiary)
    }
}
