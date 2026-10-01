import AppKit
import SwiftUI

struct OnboardingWelcomeStep: View {
  var body: some View {
    VStack(spacing: 30) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 148, height: 148)
        .shadow(color: .black.opacity(0.15), radius: 15, x: -8, y: 8)
        .accessibilityHidden(true)

      VStack(spacing: -4) {
        Text("Welcome to")
          .font(AppStyle.Typography.sectionTitle.weight(.medium))
          .foregroundStyle(AppColors.textPrimary.opacity(0.8))
          .tracking(0.2)

        Text("Purge")
          .font(AppStyle.Typography.display.weight(.semibold))
          .foregroundStyle(AppColors.textPrimary)
      }
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Welcome to Purge")
    }
    .frame(maxWidth: OnboardingLayout.contentMaxWidth, maxHeight: .infinity)
  }
}
