import SwiftUI

struct OnboardingCelebrationView: View {
  let bytesMovedToTrash: Int64
  let onContinue: () -> Void

  @State private var animatedMovedBytes: Double = 0

  var body: some View {
    VStack(spacing: AppStyle.Spacing.large) {
      Spacer(minLength: 0)

      Image(systemName: "sparkles")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(AppColors.textPrimary)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)

      VStack(spacing: AppStyle.Spacing.small) {
        if bytesMovedToTrash > 0 {
          Text(formatBytes(Int64(animatedMovedBytes)))
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .contentTransition(.numericText())
            .monospacedDigit()
            .accessibilityLabel("\(formatBytes(bytesMovedToTrash)) moved to trash, not yet reclaimed")

          Text("moved to trash, not yet reclaimed")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.secondary)
        } else {
          Text("You're all set")
            .font(.system(size: 40, weight: .bold, design: .rounded))
        }

        Text(SpaceContextTranslation.phrase(for: bytesMovedToTrash))
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, AppStyle.Spacing.xSmall)
      }
      .frame(maxWidth: OnboardingLayout.contentMaxWidth)

      Spacer(minLength: 0)

      VStack(spacing: AppStyle.Spacing.small) {
        if bytesMovedToTrash > 0 {
          Text("Empty your Trash to reclaim this space.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }

        OnboardingPrimaryButton(title: "Continue", action: onContinue)
      }
      .frame(maxWidth: OnboardingLayout.contentMaxWidth)
    }
    .padding(.horizontal, OnboardingLayout.horizontalPadding)
    .padding(.vertical, OnboardingLayout.verticalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppColors.bgBase)
    .onAppear {
      if bytesMovedToTrash > 0 {
        withAnimation(.easeOut(duration: 0.85)) {
          animatedMovedBytes = Double(bytesMovedToTrash)
        }
      }
    }
  }
}
