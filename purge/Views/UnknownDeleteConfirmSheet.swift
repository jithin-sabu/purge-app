import SwiftUI

struct UnknownDeleteConfirmSheet: View {
    let candidates: [PurgeStore.DeletionCandidate]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var primaryTitle: String {
        candidates.first?.title ?? ""
    }

    private var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var sharedExplanation: String {
        candidates.first?.safetyInfo.explanation ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.gray)
                VStack(alignment: .leading, spacing: 6) {
                    Text("We are not sure what this is")
                        .font(.title3.weight(.bold))
                    Text("Purge could not identify this file. Only delete it if you know what it is. We cannot put it back afterward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(primaryTitle)
                    .font(.headline)

                if candidates.count > 1 {
                    Text("\(candidates.count) locations will be removed:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates, id: \.path) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.path.path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(3)
                                Text(item.formattedSize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)

                Text("Combined size: \(formatBytes(totalBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Text(SafetyLevel.unknown.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SafetyLevel.unknown.color)

                Text(sharedExplanation)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue…", role: .destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }
}
