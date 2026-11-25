import SwiftUI

// MARK: - Primitives

enum SkeletonOpacity {
    static let medium: Double = 0.15
    static let light: Double = 0.14
}

struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 10
    var cornerRadius: CGFloat = AppStyle.Radius.xs

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppColors.textSecondary.opacity(SkeletonOpacity.medium))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Loading crossfade

/// Whether a loading placeholder is on screen, so its looping animations (the
/// shimmer band, the scanning ring) run only while someone can see them. True
/// outside a `ScanContentCrossfade`.
private nonisolated struct LoadingPlaceholderAnimatesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    nonisolated var loadingPlaceholderAnimates: Bool {
        get { self[LoadingPlaceholderAnimatesKey.self] }
        set { self[LoadingPlaceholderAnimatesKey.self] = newValue }
    }
}

private enum ScanContentCrossfadeTiming {
    static let fadeDuration: Double = 0.3
    /// A little longer than the fade, so the loops run until it is fully gone.
    static let fadeOutHoldNanoseconds: UInt64 = 400_000_000
}

/// Crossfades between a loading placeholder and loaded content (respects Reduce Motion).
///
/// The placeholder stays mounted at opacity 0 once loaded, so the layout does not
/// move. Its looping animations stop once it has faded out (#457): left running,
/// every row on the tab redrew an invisible shimmer each frame, which kept the
/// main thread busy while nothing on screen changed.
struct ScanContentCrossfade<Loading: View, Loaded: View>: View {
    var isLoading: Bool
    var contentAlignment: Alignment = .center
    @ViewBuilder var loading: () -> Loading
    @ViewBuilder var loaded: () -> Loaded

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True from the moment loading ends until the placeholder has faded out.
    @State private var isFadingOut = false
    @State private var fadeOutGeneration = 0

    var body: some View {
        ZStack(alignment: contentAlignment) {
            loaded()
                .opacity(isLoading ? 0 : 1)
            loading()
                .environment(\.loadingPlaceholderAnimates, isLoading || isFadingOut)
                .opacity(isLoading ? 1 : 0)
                .allowsHitTesting(isLoading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: ScanContentCrossfadeTiming.fadeDuration), value: isLoading)
        .onChange(of: isLoading) { loading in
            fadeOutGeneration += 1
            guard !loading else {
                isFadingOut = false
                return
            }
            isFadingOut = true
            let generation = fadeOutGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: ScanContentCrossfadeTiming.fadeOutHoldNanoseconds)
                guard generation == fadeOutGeneration else { return }
                isFadingOut = false
            }
        }
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

// MARK: - Deletion overlay

struct CleaningOverlay: View {
    /// Already translated, so VoiceOver reads the same text the overlay shows.
    var message = String(localized: "Cleaning…")

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: AppStyle.Spacing.small) {
                ProgressView()
                    .controlSize(.regular)
                Text(message)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
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

    /// A light band sweeping across text, in place of a spinner, while it loads.
    /// Off, it leaves the view alone, so turning it on and off keeps the text's
    /// identity and its content transitions.
    func shimmeringText(_ isActive: Bool) -> some View {
        modifier(TextShimmerModifier(isActive: isActive))
    }
}

struct TextShimmerModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 1.6
    /// The band as a share of the text's width.
    private static let bandShare: CGFloat = 0.5

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive, !reduceMotion {
                    // The same text drawn in the primary color, shown only under a band
                    // that travels from fully off the left edge to fully off the right,
                    // so the loop resets with nothing visible.
                    TimelineView(.animation) { timeline in
                        let progress = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.period) / Self.period
                        content
                            .foregroundStyle(AppColors.textPrimary)
                            .mask {
                                GeometryReader { geo in
                                    let band = geo.size.width * Self.bandShare
                                    LinearGradient(
                                        colors: [.clear, .white, .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: band)
                                    .offset(x: -band + CGFloat(progress) * (geo.size.width + band))
                                }
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
    }
}

struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.loadingPlaceholderAnimates) private var animates

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion, animates {
                    ShimmerBand()
                        .allowsHitTesting(false)
                        // Mask the gradient to the skeleton shapes, not the container bounds.
                        .mask(content)
                }
            }
    }
}

/// The moving highlight. Its own view, so the loop starts from the left edge each
/// time the band is shown again.
private struct ShimmerBand: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // The highlight band is one container-width wide and
            // travels from fully off the left edge to fully off the
            // right (offset -w … +w). Both ends of the loop are
            // therefore blank, so the linear repeat resets with
            // nothing on screen and the loop reads as seamless. A
            // 2×-width band (the earlier value) sat at the left edge
            // at phase 0, so the reset snapped a visible band back
            // into place — the jitter.
            LinearGradient(
                gradient: Gradient(colors: [
                    .clear,
                    Color.white.opacity(0.1),
                    .clear
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width)
            .offset(x: phase * geo.size.width * 2 - geo.size.width)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}
