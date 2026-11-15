import Foundation

enum OnboardingStep: Int, CaseIterable, Hashable {
  case welcome = 0
  case firstScan
  case results
  /// Asks for Full Disk Access, after the user has seen what Purge finds without it.
  case lookDeeper
}
