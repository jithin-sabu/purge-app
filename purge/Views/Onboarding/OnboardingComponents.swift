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
  static let scrollingListMaxHeight: CGFloat = 460
  /// Fixed height for streamed scan rows so the list does not reflow per item.
  static let scanRowHeight: CGFloat = 56
}

/// Full-width capsule used for the onboarding footer actions — taller and larger-typed
/// than `AppButtonStyle`, which is sized for in-app chrome.
struct OnboardingCapsuleButtonStyle: ButtonStyle {
  enum Variant {
    case filled
    case elevated
  }

  var variant: Variant = .filled

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold, design: .rounded))
      .tracking(0.15)
      .foregroundStyle(variant == .filled ? AppColors.buttonPrimaryText : AppColors.textPrimary)
      .frame(width: OnboardingLayout.buttonWidth)
      .padding(.vertical, 8)
      .background(background(isPressed: configuration.isPressed), in: Capsule(style: .continuous))
      .overlay {
        if variant == .elevated {
          Capsule(style: .continuous)
            .stroke(AppColors.borderSubtle)
        }
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isEnabled)
  }

  private func background(isPressed: Bool) -> Color {
    switch variant {
    case .filled:
      return AppColors.buttonPrimaryBg
    case .elevated:
      return isPressed ? AppColors.bgOverlay : AppColors.bgElevated
    }
  }
}

struct OnboardingPrimaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isEnabled: Bool = true
  var isLoading: Bool = false
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
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
              .tint(AppColors.buttonPrimaryText)
          }
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
        }
      }
    }
    .buttonStyle(OnboardingCapsuleButtonStyle(variant: .filled))
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
    .buttonStyle(OnboardingCapsuleButtonStyle(variant: .elevated))
  }
}

struct OnboardingPermissionRow: View {
  let title: String
  let description: String
  let badgeText: String
  let badgeTone: AppBadge.Tone
  let buttonTitle: String
  var isGranted: Bool = false
  var statusText: String? = nil
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
          AppBadge(text: badgeText, tone: badgeTone)
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let statusText, !isGranted {
          Text(statusText)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)

      Button(action: action) {
        HStack(spacing: 6) {
          if isGranted {
            Image(systemName: "checkmark")
              .font(.caption.weight(.semibold))
          }
          Text(isGranted ? "Enabled" : buttonTitle)
            .lineLimit(1)
        }
      }
      .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
      .fixedSize(horizontal: true, vertical: false)
      .layoutPriority(0)
      .disabled(isGranted)
      .accessibilityLabel(isGranted ? "\(title), enabled" : "\(buttonTitle) for \(title)")
    }
    .padding(.horizontal, AppStyle.Spacing.medium)
    .padding(.vertical, AppStyle.Spacing.small)
    .background(AppColors.bgCard, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppColors.borderSubtle)
    }
    .shadow(color: .black.opacity(0.15), radius: 15, x: -8, y: 8)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isGranted)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: statusText)
  }
}

struct OnboardingProgressBar: View {
  let progress: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.primary.opacity(0.1))
        RoundedRectangle(cornerRadius: 4, style: .continuous)
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
    Text("That's roughly")
      .font(.title3.weight(.regular))
      .foregroundStyle(.secondary)
  }

  private var comparisonChips: some View {
    HStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Text("or")
            .font(.title3.weight(.regular))
            .foregroundStyle(.tertiary)
        }

        OnboardingSizeComparisonChip(item: item)
      }
    }
  }

  private var accessibilityLabel: String {
    let body = items.map(\.label).joined(separator: " or ")
    return "That's roughly \(body)"
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
    .font(.title3.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background {
      Capsule(style: .continuous)
        .fill(Color.primary.opacity(0.07))
    }
    .overlay {
      Capsule(style: .continuous)
        .stroke(Color.primary.opacity(0.16), lineWidth: 1)
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
        .foregroundStyle(.tertiary)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)

      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)

      Spacer(minLength: AppStyle.Spacing.xxSmall)

      Text(formattedSize)
        .font(.callout)
        .foregroundStyle(.secondary)
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
      .font(.system(size: 26, weight: .semibold, design: .rounded))
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
      .font(.system(size: 26, weight: .semibold, design: .rounded))
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

private struct OnboardingScrollContentHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct OnboardingScrollViewportHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Scroll view that fades the bottom edge before content clips, once the list nears the viewport limit.
struct OnboardingFadingScrollView<Content: View>: View {
  let maxHeight: CGFloat
  var fadeHeight: CGFloat = 56
  var fadeTopClearance: CGFloat = 28
  @ViewBuilder let content: () -> Content

  @State private var contentHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  /// Stays on once the list has neared overflow so the edge does not pop in mid-reveal.
  @State private var fadeEngaged = false

  private var shouldEngageFade: Bool {
    guard viewportHeight > 0 else { return false }
    return contentHeight > viewportHeight - visibleFadeHeight
  }

  private var showsFade: Bool {
    fadeEngaged || shouldEngageFade
  }

  private var visibleFadeHeight: CGFloat {
    max(0, fadeHeight - fadeTopClearance)
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      content()
        .background {
          GeometryReader { proxy in
            Color.clear
              .preference(key: OnboardingScrollContentHeightKey.self, value: proxy.size.height)
          }
        }
    }
    .frame(maxHeight: maxHeight)
    .background {
      GeometryReader { proxy in
        Color.clear
          .preference(key: OnboardingScrollViewportHeightKey.self, value: proxy.size.height)
      }
    }
    .onPreferenceChange(OnboardingScrollContentHeightKey.self) { contentHeight = $0 }
    .onPreferenceChange(OnboardingScrollViewportHeightKey.self) { viewportHeight = $0 }
    .onChange(of: shouldEngageFade) { engage in
      if engage {
        fadeEngaged = true
      } else if contentHeight < viewportHeight - fadeHeight * 2 {
        fadeEngaged = false
      }
    }
    .overlay(alignment: .bottom) {
      if showsFade {
        OnboardingScrollBottomFade(height: fadeHeight, topClearance: fadeTopClearance)
          .allowsHitTesting(false)
          .transaction { $0.animation = nil }
      }
    }
  }
}

/// Fades scroll content into the onboarding canvas so the edge matches the window background.
private struct OnboardingScrollBottomFade: View {
  let height: CGFloat
  let topClearance: CGFloat

  private var fadeStartLocation: CGFloat {
    min(0.95, max(0, topClearance / max(height, 1)))
  }

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: AppColors.bgBase.opacity(0), location: 0),
        .init(color: AppColors.bgBase.opacity(0), location: fadeStartLocation),
        .init(color: AppColors.bgBase.opacity(0.28), location: fadeStartLocation + (1 - fadeStartLocation) * 0.45),
        .init(color: AppColors.bgBase.opacity(0.76), location: fadeStartLocation + (1 - fadeStartLocation) * 0.75),
        .init(color: AppColors.bgBase, location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: height)
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
