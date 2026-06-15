import SwiftUI

// MARK: - Row count

enum SkeletonRowCount {
    static let defaultCount = 8
    static let minimum = 6
    static let maximum = 12

    static func clamped(_ count: Int, default defaultCount: Int = defaultCount) -> Int {
        guard count > 0 else { return defaultCount }
        return max(minimum, min(maximum, count))
    }
}

// MARK: - Primitives

enum SkeletonOpacity {
    static let medium: Double = 0.15
    static let light: Double = 0.14
}

struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(SkeletonOpacity.medium))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// Horizontal skeleton bar that expands to the width of its container.
struct SkeletonFillBar: View {
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(SkeletonOpacity.medium))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Loading crossfade

/// Crossfades between a loading placeholder and loaded content (respects Reduce Motion).
struct ScanContentCrossfade<Loading: View, Loaded: View>: View {
    var isLoading: Bool
    @ViewBuilder var loading: () -> Loading
    @ViewBuilder var loaded: () -> Loaded

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            loaded()
                .opacity(isLoading ? 0 : 1)
            loading()
                .opacity(isLoading ? 1 : 0)
                .allowsHitTesting(isLoading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isLoading)
    }
}

// MARK: - Streamed row transitions

private struct ScanRowAppearModifier: ViewModifier {
    let blurRadius: CGFloat
    let opacity: Double
    let yOffset: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blurRadius)
            .opacity(opacity)
            .offset(y: yOffset)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var scanRowInsertion: AnyTransition {
        .modifier(
            active: ScanRowAppearModifier(
                blurRadius: 8,
                opacity: 0,
                yOffset: 12,
                scale: 0.985
            ),
            identity: ScanRowAppearModifier(
                blurRadius: 0,
                opacity: 1,
                yOffset: 0,
                scale: 1
            )
        )
    }
}

// MARK: - List placeholder

/// List-shaped placeholder rows shown while a tab scan is in progress.
///
/// Renders the real `ScanResultRow` view in placeholder mode so the loading
/// state shares identical paddings, fonts, stack directions, and list styling
/// with the loaded state. The crossfade handled by `ScanContentCrossfade` then
/// has no layout shift to fight.
struct ScanListSkeletonPlaceholder: View {
    var rowCount: Int = SkeletonRowCount.defaultCount

    var body: some View {
        List {
            ForEach(0..<rowCount, id: \.self) { index in
                ScanResultRow.placeholder(seed: index)
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading results")
    }
}

// MARK: - Deletion overlay

struct CleaningOverlay: View {
    var message: String = "Cleaning…"

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
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
                    // Mask the gradient to the skeleton shapes, not the container bounds.
                    .mask(content)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
