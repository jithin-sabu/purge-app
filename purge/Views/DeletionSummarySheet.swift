import SwiftUI

struct DeletionSummarySheet: View {
    let report: DeletionReport
    let onDone: () -> Void
    let onScanAgain: () -> Void

    @State private var animatedFreedBytes: Double = 0

    private var freedBytesForDisplay: Int64 {
        report.actualFreedBytes > 0 ? report.actualFreedBytes : report.totalDeleted
    }

    private var showsNothingFreed: Bool {
        freedBytesForDisplay == 0
    }

    private var acrossItemsSubtitle: String? {
        let n = report.deletedItems.count
        guard n > 0 else { return nil }
        return n == 1 ? "across 1 item" : "across \(n) items"
    }

    private var userVisibleSkippedItems: [SkippedDeletionItem] {
        report.skippedItems.filter(\.isUserVisible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            successHeader
                .padding(.bottom, 20)

            heroBlock
                .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 12)

            Text("Deleted Items (\(report.deletedItems.count))")
                .font(.headline.weight(.semibold))
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.deletedItems) { item in
                        deletedRow(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !report.failedItems.isEmpty {
                Divider()
                    .padding(.vertical, 12)

                Text("Failed Items (\(report.failedItems.count))")
                    .font(.headline.weight(.semibold))
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(report.failedItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.path)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !userVisibleSkippedItems.isEmpty {
                Divider()
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skipped for safety (\(userVisibleSkippedItems.count))")
                        .font(.headline)
                    List(userVisibleSkippedItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path)
                                .lineLimit(1)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: 140)
                }
            }

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Scan Again", action: onScanAgain)
                    .buttonStyle(.bordered)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .onAppear {
            guard !showsNothingFreed else {
                animatedFreedBytes = 0
                return
            }
            withAnimation(.easeOut(duration: 0.8)) {
                animatedFreedBytes = Double(freedBytesForDisplay)
            }
        }
    }

    private var successHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("All done")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All done")
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsNothingFreed {
                Text("Nothing to clean")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(formatBytes(Int64(animatedFreedBytes))) freed")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let acrossItemsSubtitle {
                Text(acrossItemsSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deletedRow(_ item: DeletedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(friendlyTitle(for: item))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(formatBytes(item.sizeBytes))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func friendlyTitle(for item: DeletedItem) -> String {
        if let name = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let fallback = URL(fileURLWithPath: item.path).lastPathComponent
        return fallback.isEmpty ? item.path : fallback
    }
}
