import SwiftUI

struct DeletionConfirmSheet: View {
    let candidates: [PurgeStore.DeletionCandidate]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var unknownCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { $0.safetyInfo.level == .unknown }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Safe + Check First only (shown as lower-risk additions in the elevated layout).
    private var benignCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { $0.safetyInfo.level == .safe || $0.safetyInfo.level == .medium }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var showsElevatedRiskLayout: Bool {
        !unknownCandidates.isEmpty
    }

    private static let groupedSectionOrder: [SafetyLevel] = [.safe, .medium]

    private var groupedBenign: [(SafetyLevel, [PurgeStore.DeletionCandidate])] {
        let grouped = Dictionary(grouping: benignCandidates, by: { $0.safetyInfo.level })
        return Self.groupedSectionOrder.compactMap { level in
            guard let values = grouped[level], !values.isEmpty else { return nil }
            return (level, values.sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }

    var body: some View {
        Group {
            if showsElevatedRiskLayout {
                elevatedRiskLayout
            } else {
                standardLayout
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: showsElevatedRiskLayout ? 480 : 420)
    }

    private func locationLabel(for item: PurgeStore.DeletionCandidate) -> String {
        item.subtitle ?? item.path.lastPathComponent
    }

    private var elevatedRiskLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            elevatedWarningHeader

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !unknownCandidates.isEmpty {
                            Text(SafetyLevel.unknown.displayName)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(
                                "Purge could not confidently classify these folders. Only proceed if you know what they are."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            ForEach(unknownCandidates) { item in
                                elevatedItemCard(
                                    title: item.title,
                                    explanation: item.safetyInfo.explanation,
                                tint: Color.primary.opacity(0.04)
                                )
                            }
                        }

                        if !benignCandidates.isEmpty {
                            Divider()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            Text("Also included in this cleanup")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(benignCandidates) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.medium))
                                        Text(locationLabel(for: item))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(item.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    // ScrollView content needs a concrete width; otherwise it hugs the text and the card fill stops early.
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(width: proxy.size.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Total recoverable: \(formatBytes(totalBytes))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue…") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(4)
    }

    @ViewBuilder
    private var elevatedWarningHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("We are not sure what some of these are")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text(
                    """
                    Purge could not identify every selected folder. Only continue if you know it is safe to remove. \
                    You will be asked to confirm again before anything is deleted.
                    """
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func elevatedItemCard(title: String, explanation: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to clean?")
                .font(.title3)
                .fontWeight(.semibold)

            Text("These items will be moved to Trash. You can recover anything from Trash if you change your mind.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(groupedBenign, id: \.0) { level, items in
                    Section(level.displayName) {
                        ForEach(items) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(locationLabel(for: item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let command = item.reinstallCommand, !command.isEmpty {
                                        Text(command)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(item.formattedSize)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Text("Total recoverable: \(formatBytes(totalBytes))")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Clean now") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.textPrimary)
            }
        }
    }
}
