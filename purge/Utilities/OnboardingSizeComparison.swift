import Foundation

struct OnboardingSizeComparisonItem: Identifiable, Equatable {
  let symbol: String
  /// What the UI shows, already localized: "Photoshop, 4 times over".
  let displayLabel: String

  var id: String { symbol + displayLabel }
}

enum OnboardingSizeComparison {
  static func items(for bytes: Int64) -> [OnboardingSizeComparisonItem]? {
    guard let item = SizeComparisonCatalog.item(for: bytes) else { return nil }

    return [item]
  }
}
