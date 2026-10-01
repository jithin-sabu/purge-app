import AppKit
import SwiftUI

struct OnboardingScanFinding: Identifiable, Equatable {
  /// Stable identity used to deduplicate streamed results: the item's file path,
  /// falling back to a category+source key when no path is available. Never a
  /// per-render UUID, so repeat emissions update the existing row instead of
  /// appending a duplicate.
  let id: String
  let title: String
  let formattedSize: String
  /// Same brand artwork the in-app scan lists use, so onboarding rows aren't all generic folders.
  let icon: AdaptiveBrandIconImage.Source
}

extension OnboardingScanFinding {
  init(candidate: PurgeStore.DeletionCandidate, icon: AdaptiveBrandIconImage.Source) {
    self.init(
      id: candidate.path.standardizedFileURL.path,
      title: candidate.title,
      formattedSize: candidate.formattedSize,
      icon: icon
    )
  }
}

struct OnboardingLayout {
  static let contentMaxWidth: CGFloat = 520
  static let horizontalPadding: CGFloat = 48
  static let verticalPadding: CGFloat = 40
  static let buttonWidth: CGFloat = 240
  /// Space between the results (total and category list) and the action group
  /// below it. Clearly more than the 40pt between the total and the list inside
  /// `OnboardingResultsStep`, so the two read as separate groups, without the old
  /// stretched gap.
  static let resultsFooterGap: CGFloat = 64
  /// Fixed height for streamed scan rows so the list does not reflow per item.
  static let scanRowHeight: CGFloat = 56
}

struct OnboardingPrimaryButton: View {
  let title: String
  /// Before the title, for an icon that names the action (trash).
  var leadingSystemImage: String? = nil
  /// After the title, for an icon that points onward (arrow).
  var systemImage: String? = nil
  var isEnabled: Bool = true
  var isLoading: Bool = false
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let leadingSystemImage {
          Image(systemName: leadingSystemImage)
            .font(.system(size: 12, weight: .semibold))
        }

        Text(title)

        if isLoading {
          if reduceMotion {
            Image(systemName: "clock")
              .font(.system(size: 12, weight: .semibold))
          } else {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.62)
              .frame(width: 13, height: 13)
          }
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
        }
      }
    }
    .buttonStyle(.purge(.primary, size: .large, width: .fixed(OnboardingLayout.buttonWidth)))
    .disabled(!isEnabled || isLoading)
    .keyboardShortcut(.return, modifiers: [])
  }
}

struct OnboardingSecondaryButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
    }
    .buttonStyle(.purge(.secondary, size: .large, width: .fixed(OnboardingLayout.buttonWidth)))
  }
}

struct OnboardingProgressBar: View {
  let progress: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
          .fill(AppColors.fillSecondary)
        RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
          .fill(AppColors.textPrimary)
          .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
          .animation(.easeInOut(duration: 0.3), value: progress)
      }
    }
    .frame(height: 6)
    .accessibilityLabel("Scan progress")
    .accessibilityValue("\(Int(progress * 100)) percent")
  }
}

struct OnboardingSizeComparisonLine: View {
  let items: [OnboardingSizeComparisonItem]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      inlineLayout
      stackedLayout
    }
    .multilineTextAlignment(.center)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var inlineLayout: some View {
    HStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
      prefixLabel
      comparisonChips
    }
  }

  private var stackedLayout: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
      prefixLabel
      comparisonChips
    }
  }

  private var prefixLabel: some View {
    Text("That's room for")
      .font(AppStyle.Typography.sectionTitle.weight(.regular))
      .foregroundStyle(AppColors.textSecondary)
  }

  private var comparisonChips: some View {
    HStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Text("or")
            .font(AppStyle.Typography.sectionTitle.weight(.regular))
            .foregroundStyle(AppColors.textTertiary)
        }

        OnboardingSizeComparisonChip(item: item)
      }
    }
  }

  private var accessibilityLabel: String {
    let body = items.map(\.label).joined(separator: " or ")
    return "That's room for \(body)"
  }
}

private struct OnboardingSizeComparisonChip: View {
  let item: OnboardingSizeComparisonItem

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: item.symbol)
        .imageScale(.small)
        .accessibilityHidden(true)

      Text(item.label)
        .lineLimit(1)
    }
    .font(AppStyle.Typography.sectionTitle.weight(.medium))
    .foregroundStyle(AppColors.textSecondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background {
      Capsule(style: .continuous)
        .fill(AppColors.fillSecondary)
    }
    .overlay {
      Capsule(style: .continuous)
        .stroke(AppColors.borderStrong, lineWidth: 1)
    }
  }
}

struct OnboardingResultsCategoryRow: View {
  let symbol: String
  let title: String
  let formattedSize: String

  private static let sizeColumnWidth: CGFloat = 72

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(AppColors.textTertiary)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)

      Text(title)
        .font(AppStyle.Typography.callout)
        .foregroundStyle(AppColors.textSecondary)

      Spacer(minLength: AppStyle.Spacing.xxSmall)

      Text(formattedSize)
        .font(AppStyle.Typography.callout)
        .foregroundStyle(AppColors.textSecondary)
        .monospacedDigit()
        .frame(width: Self.sizeColumnWidth, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(formattedSize)")
  }
}

struct OnboardingStepTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(AppStyle.Typography.title)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

struct OnboardingLoadingStepTitle: View {
  let baseText: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dotCount = 1
  @State private var dotAnimationTask: Task<Void, Never>?

  private static let dotCycleInterval: Duration = .milliseconds(1000)

  var body: some View {
    Text(displayText)
      .font(AppStyle.Typography.title)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
      .accessibilityLabel("\(baseText).")
      .onAppear { startDotAnimationIfNeeded() }
      .onDisappear {
        dotAnimationTask?.cancel()
        dotAnimationTask = nil
      }
  }

  private var displayText: String {
    if reduceMotion {
      return "\(baseText)."
    }
    return baseText + String(repeating: ".", count: dotCount)
  }

  private func startDotAnimationIfNeeded() {
    dotAnimationTask?.cancel()

    guard !reduceMotion else {
      dotCount = 1
      return
    }

    dotCount = 1
    dotAnimationTask = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.dotCycleInterval)
        guard !Task.isCancelled else { break }
        dotCount = dotCount >= 3 ? 1 : dotCount + 1
      }
    }
  }
}

private struct OnboardingBlurInModifier: ViewModifier {
  let index: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var revealed = false

  func body(content: Content) -> some View {
    content
      .blur(radius: revealed || reduceMotion ? 0 : 10)
      .opacity(revealed || reduceMotion ? 1 : 0)
      .onAppear {
        guard !revealed else { return }
        if reduceMotion {
          revealed = true
        } else {
          let delay = Double(index) * 0.08
          withAnimation(.easeOut(duration: 0.45).delay(delay)) {
            revealed = true
          }
        }
      }
  }
}

extension View {
  func onboardingBlurIn(index: Int) -> some View {
    modifier(OnboardingBlurInModifier(index: index))
  }
}

/// Scroll view whose bottom edge fades and blurs into the window background.
/// It fills the rest of the step, so the fade sits on the window's bottom edge.
///
/// Both effects act on the rows only, so an empty stretch of list shows nothing:
/// the fade is a mask on the list, which lets the window background show through
/// rather than painting over it, and the blur comes from each row's
/// `onboardingScrollEdgeBlur()` as it nears the edge.
struct OnboardingFadingScrollView<Content: View>: View {
  var fadeHeight: CGFloat = OnboardingScrollEdge.fadeHeight
  var fadeTopClearance: CGFloat = OnboardingScrollEdge.topClearance
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollView(showsIndicators: false) {
      content()
    }
    .frame(maxHeight: .infinity)
    .mask {
      VStack(spacing: 0) {
        Rectangle()
        OnboardingScrollBottomFadeMask(height: fadeHeight, topClearance: fadeTopClearance)
      }
    }
  }
}

enum OnboardingScrollEdge {
  static let fadeHeight: CGFloat = 140
  static let topClearance: CGFloat = 24
  /// Blur on a row whose middle has reached the bottom edge.
  static let maxBlurRadius: CGFloat = 8
}

/// Opaque at the top, clear at the bottom: rows fade out and the window
/// background shows through where they were.
private struct OnboardingScrollBottomFadeMask: View {
  let height: CGFloat
  let topClearance: CGFloat

  private var fadeStartLocation: CGFloat {
    min(0.95, max(0, topClearance / max(height, 1)))
  }

  /// Where along the fade a stop sits, from the clear band (0) to the bottom (1).
  private func location(_ fraction: CGFloat) -> CGFloat {
    fadeStartLocation + (1 - fadeStartLocation) * fraction
  }

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: fadeStartLocation),
        .init(color: .black.opacity(0.8), location: location(0.35)),
        .init(color: .black.opacity(0.4), location: location(0.65)),
        .init(color: .black.opacity(0.1), location: location(0.85)),
        .init(color: .black.opacity(0), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: height)
  }
}

extension View {
  /// Blurs a row in an `OnboardingFadingScrollView` as it moves into the bottom
  /// fade, more the closer its middle gets to the edge. Per row rather than a
  /// blur layer over the list, so empty space under a short list stays clear.
  /// Needs macOS 14 for the scroll view geometry; earlier, rows only fade.
  @ViewBuilder
  func onboardingScrollEdgeBlur() -> some View {
    if #available(macOS 14.0, *) {
      visualEffect { effect, proxy in
        effect.blur(radius: OnboardingScrollEdgeBlur.radius(
          rowHeight: proxy.size.height,
          visibleBottom: proxy.bounds(of: .scrollView)?.maxY
        ))
      }
    } else {
      self
    }
  }
}

nonisolated enum OnboardingScrollEdgeBlur {
  /// `visibleBottom` is the scroll view's bottom edge in the row's own
  /// coordinates. Zero until the row's middle enters the fade band.
  static func radius(rowHeight: CGFloat, visibleBottom: CGFloat?) -> CGFloat {
    guard let visibleBottom else { return 0 }
    let band = OnboardingScrollEdge.fadeHeight - OnboardingScrollEdge.topClearance
    let distanceAboveEdge = visibleBottom - rowHeight / 2
    let progress = min(1, max(0, 1 - distanceAboveEdge / band))
    return progress * OnboardingScrollEdge.maxBlurRadius
  }
}

private struct OnboardingStepTransition: ViewModifier {
  let blur: CGFloat
  let opacity: Double

  func body(content: Content) -> some View {
    content
      .blur(radius: blur)
      .opacity(opacity)
  }
}

enum OnboardingTransitions {
  static let dismissDuration: TimeInterval = 0.45
  static let dismissBlurRadius: CGFloat = 12
  private static let listRowRemovalBlur: CGFloat = 10

  static func stepTransition(reduceMotion: Bool) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .modifier(
      active: OnboardingStepTransition(blur: 8, opacity: 0),
      identity: OnboardingStepTransition(blur: 0, opacity: 1)
    )
  }

  /// Rows leaving a list during onboarding cleaning — blur and fade, no slide.
  static func listRowRemoval(reduceMotion: Bool) -> AnyTransition {
    .asymmetric(
      insertion: .identity,
      removal: reduceMotion
        ? .opacity
        : .modifier(
          active: OnboardingStepTransition(blur: listRowRemovalBlur, opacity: 0),
          identity: OnboardingStepTransition(blur: 0, opacity: 1)
        )
    )
  }
}

private struct OnboardingExitBlurModifier: ViewModifier {
  let isExiting: Bool
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    content
      .blur(radius: isExiting && !reduceMotion ? OnboardingTransitions.dismissBlurRadius : 0)
      .opacity(isExiting && !reduceMotion ? 0 : 1)
  }
}

extension View {
  func onboardingExitBlur(isExiting: Bool, reduceMotion: Bool) -> some View {
    modifier(OnboardingExitBlurModifier(isExiting: isExiting, reduceMotion: reduceMotion))
  }
}

func openFullDiskAccessSettings() {
  guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
    return
  }
  NSWorkspace.shared.open(url)
}
