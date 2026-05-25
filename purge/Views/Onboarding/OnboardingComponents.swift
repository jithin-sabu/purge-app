import AppKit
import SwiftUI

struct OnboardingScanFinding: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let formattedSize: String
}

struct OnboardingLayout {
  static let contentMaxWidth: CGFloat = 520
  static let horizontalPadding: CGFloat = 48
  static let verticalPadding: CGFloat = 40
  static let buttonWidth: CGFloat = 260
}

struct OnboardingPrimaryButton: View {
  let title: String
  var isEnabled: Bool = true
  var isLoading: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      CleaningButtonLabel(
        title: title,
        systemImage: nil,
        isCleaning: isLoading,
        spinnerTint: .white
      )
        .frame(minWidth: OnboardingLayout.buttonWidth)
    }
    .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
    .disabled(!isEnabled || isLoading)
    .keyboardShortcut(.return, modifiers: [])
  }
}

struct OnboardingSecondaryButton: View {
  enum Style {
    case plain
    case outlined
  }

  let title: String
  var style: Style = .plain
  let action: () -> Void

  var body: some View {
    Group {
      if style == .outlined {
        Button(action: action) {
          Text(title)
            .font(.body.weight(.semibold))
            .frame(minWidth: OnboardingLayout.buttonWidth)
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
      } else {
        Button(action: action) {
          Text(title)
            .font(.subheadline.weight(.medium))
            .frame(minWidth: OnboardingLayout.buttonWidth)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
  }
}

struct OnboardingFeatureChip: View {
  let symbol: String
  let label: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(AppStyle.accent)
        .frame(width: 52, height: 52)
        .background(AppStyle.accent.opacity(0.12), in: Circle())

      Text(label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }
}

struct OnboardingPermissionRow: View {
  let symbol: String
  let title: String
  let description: String
  let badgeText: String
  let badgeTone: AppBadge.Tone
  var isGranted: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(AppStyle.accent)
        .frame(width: 40, height: 40)
        .background(AppStyle.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.subheadline.weight(.semibold))
          AppBadge(text: badgeText, tone: badgeTone)
          if isGranted {
            Image(systemName: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(AppStyle.safe)
              .accessibilityLabel("Granted")
          }
        }
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(AppStyle.Spacing.small)
    .background(AppStyle.panel, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppStyle.hairline)
    }
    .accessibilityElement(children: .combine)
  }
}

struct OnboardingNotificationPreviewCard: View {
  let appName: String
  let timeLabel: String
  let bodyText: String

  var body: some View {
    HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(appName)
            .font(.subheadline.weight(.semibold))
          Text("·")
            .foregroundStyle(.tertiary)
          Text(timeLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Text(bodyText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(AppStyle.Spacing.small)
    .background(AppStyle.elevated, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppStyle.hairline)
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(appName), \(timeLabel). \(bodyText)")
  }
}

struct OnboardingToggleRow: View {
  let title: String
  let subtitle: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(AppStyle.accent)
    }
    .padding(AppStyle.Spacing.small)
    .background(AppStyle.panel, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppStyle.hairline)
    }
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
          .fill(AppStyle.accent)
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
      .font(.system(size: 28, weight: .bold, design: .rounded))
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
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
  var fadeHeight: CGFloat = 52
  @ViewBuilder let content: () -> Content

  @State private var contentHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  /// Stays on once the list has neared overflow so the edge does not pop in mid-reveal.
  @State private var fadeEngaged = false

  private var shouldEngageFade: Bool {
    guard viewportHeight > 0 else { return false }
    return contentHeight > viewportHeight - fadeHeight
  }

  private var showsFade: Bool {
    fadeEngaged || shouldEngageFade
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
        OnboardingScrollBottomFade(height: fadeHeight)
          .allowsHitTesting(false)
          .transaction { $0.animation = nil }
      }
    }
  }
}

/// Fades scroll content into the onboarding canvas so the edge matches the window background.
private struct OnboardingScrollBottomFade: View {
  let height: CGFloat

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: AppStyle.canvas.opacity(0), location: 0),
        .init(color: AppStyle.canvas.opacity(0.25), location: 0.35),
        .init(color: AppStyle.canvas.opacity(0.72), location: 0.7),
        .init(color: AppStyle.canvas, location: 1),
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
