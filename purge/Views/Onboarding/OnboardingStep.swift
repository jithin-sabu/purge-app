import Foundation

enum OnboardingStep: Int, CaseIterable, Hashable {
  case welcome = 0
  case permissions
  case firstScan
  case results
  case cleaning
  case celebration
}
