import Foundation

struct OnboardingSizeComparisonItem: Identifiable, Equatable {
  let symbol: String
  let label: String
  var localizedLabel: String? = nil

  var displayLabel: String { localizedLabel ?? NSLocalizedString(label, comment: "Storage size comparison") }

  var id: String { symbol + label }
}

enum OnboardingSizeComparison {
  static func items(for bytes: Int64) -> [OnboardingSizeComparisonItem]? {
    guard let item = SizeComparisonCatalog.item(for: bytes) else { return nil }

    return [item]
  }
}
