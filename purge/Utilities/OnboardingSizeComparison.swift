import Foundation

struct OnboardingSizeComparisonItem: Identifiable, Equatable {
  let symbol: String
  let label: String

  var id: String { symbol + label }
}

enum OnboardingSizeComparison {
  private static let oneMegabyte: Int64 = 1024 * 1024

  static func items(for bytes: Int64) -> [OnboardingSizeComparisonItem]? {
    guard bytes >= oneMegabyte else { return nil }
    guard let item = SizeComparisonCatalog.item(for: bytes) else { return nil }

    return [item]
  }
}
