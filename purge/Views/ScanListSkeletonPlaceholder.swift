import SwiftUI

/// List-shaped placeholder rows shown while a tab scan is in progress (empty result set).
struct ScanListSkeletonPlaceholder: View {
    var rowCount: Int = 8

    var body: some View {
        List {
            ForEach(0..<rowCount, id: \.self) { index in
                skeletonRow(index: index)
            }
        }
        .listStyle(.inset)
    }

    private func skeletonRow(index: Int) -> some View {
        // Deterministic widths per row (avoids layout jitter from random values).
        let primaryWidth: CGFloat = 120 + CGFloat((index * 17) % 81)
        let secondaryWidth: CGFloat = 80 + CGFloat((index * 13) % 41)
        let trailingWidth: CGFloat = 52 + CGFloat((index * 11) % 24)

        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 8, height: 8)

            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: primaryWidth, height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: secondaryWidth, height: 10)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: trailingWidth, height: 14)
        }
        .padding(.vertical, 4)
        .shimmering()
    }
}

// MARK: - Shimmer

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            gradient: Gradient(colors: [
                                .clear,
                                Color.white.opacity(0.1),
                                .clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 2)
                        .offset(x: phase * geo.size.width * 2 - geo.size.width)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .clipped()
    }
}
