import Foundation

enum LifetimeSizeComparison {
  static func item(for bytes: Int64) -> OnboardingSizeComparisonItem? {
    SizeComparisonCatalog.item(for: bytes)
  }
}
