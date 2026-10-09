import Foundation

/// Size anchors drawn from things that take up space on a Mac, phrased as
/// what the freed space has room for ("room for 3 macOS updates", "room for
/// Photoshop, four times over"). Everyone has met most of these as a disk
/// hog: desktop screenshots, Electron apps, the "not enough space for this
/// update" dialog.
///
/// Because every anchor scales by a count, a handful of MB–GB anchors covers
/// everything from a small cache sweep to a multi-terabyte lifetime total.
enum SizeComparisonCatalog {
  enum Phrasing {
    /// "3 macOS updates" — for things you'd naturally count. `many` follows
    /// the number.
    case counted(one: String, many: String)
    /// "Photoshop, four times over" — for one big thing, repeated.
    case timesOver(one: String, name: String)
  }

  struct Anchor {
    let bytes: Int64
    let symbol: String
    let phrasing: Phrasing
  }

  private static let mb: Int64 = 1024 * 1024
  private static let gb: Int64 = 1024 * 1024 * 1024

  /// Below this a comparison is noise; the byte count says enough.
  private static let minimumBytes: Int64 = 5 * mb
  /// "Room for" is a promise, so counts round down and must reach one.
  private static let minMultiplier = 1.0
  /// Past this, the number stops meaning anything.
  private static let maxMultiplier = 20_000.0
  /// Small counts read best: "room for Photoshop, twice over" lands, "room
  /// for Photoshop, 23 times over" does not.
  private static let idealMultiplier = 2.0
  /// How much worse than the best fit an anchor may score and still be a
  /// candidate, in log10 units — roughly "within a factor of two as far off".
  private static let scoreTolerance = 0.3

  static let anchors: [Anchor] = [
    Anchor(
      bytes: 2 * mb, symbol: "camera.viewfinder",
      phrasing: .counted(one: "one more screenshot", many: "more screenshots")
    ),
    Anchor(
      bytes: 500 * mb, symbol: "bubble.left.and.bubble.right.fill",
      phrasing: .timesOver(one: "Slack", name: "Slack")
    ),
    Anchor(
      bytes: (12 * gb) / 10, symbol: "globe",
      phrasing: .counted(one: "a copy of Chrome", many: "copies of Chrome")
    ),
    Anchor(
      bytes: 5 * gb, symbol: "paintbrush.fill",
      phrasing: .timesOver(one: "Photoshop", name: "Photoshop")
    ),
    Anchor(
      bytes: 12 * gb, symbol: "apple.logo",
      phrasing: .counted(one: "the next macOS update", many: "macOS updates")
    ),
    Anchor(
      bytes: 12 * gb, symbol: "hammer.fill",
      phrasing: .counted(one: "a fresh copy of Xcode", many: "copies of Xcode")
    ),
    Anchor(
      bytes: 70 * gb, symbol: "pianokeys",
      phrasing: .timesOver(one: "Logic Pro and every sound pack", name: "full Logic Pro")
    ),
    Anchor(
      bytes: 105 * gb, symbol: "gamecontroller.fill",
      phrasing: .timesOver(one: "all of GTA V", name: "GTA V")
    ),
    Anchor(
      bytes: 256 * gb, symbol: "laptopcomputer",
      phrasing: .counted(one: "a full base MacBook Air", many: "full base MacBook Airs")
    ),
  ]

  /// Picks the anchor whose multiplier lands closest to `idealMultiplier` on a
  /// log scale, so the phrasing stays readable at any size. Among the closest
  /// few, the byte count itself selects one — deterministic (the same size
  /// always yields the same line) but varied across different sizes.
  static func item(for bytes: Int64) -> OnboardingSizeComparisonItem? {
    guard bytes >= minimumBytes else { return nil }

    let scored = anchors.compactMap { anchor -> (anchor: Anchor, multiplier: Double, score: Double)? in
      let multiplier = Double(bytes) / Double(anchor.bytes)
      guard multiplier >= minMultiplier, multiplier <= maxMultiplier else { return nil }
      return (anchor, multiplier, abs(log10(multiplier) - log10(idealMultiplier)))
    }

    guard let best = scored.min(by: { $0.score < $1.score }) else { return nil }

    // Vary only among anchors that fit about as well as the best one, so
    // picking for variety never costs a noticeably more readable line.
    let bestFits = Array(
      scored
        .filter { $0.score <= best.score + scoreTolerance }
        .sorted { $0.score < $1.score }
        .prefix(3)
    )
    let pick = bestFits[stableIndex(for: bytes, count: bestFits.count)]

    return OnboardingSizeComparisonItem(
      symbol: pick.anchor.symbol,
      label: label(for: pick.anchor, multiplier: pick.multiplier),
      localizedLabel: displayLabel(for: pick.anchor, multiplier: pick.multiplier)
    )
  }

  private static func displayLabel(for anchor: Anchor, multiplier: Double) -> String {
    let count = max(1, Int(multiplier.rounded(.down)))
    switch anchor.phrasing {
    case let .counted(one, many):
      let single = NSLocalizedString(one, comment: "Storage size comparison")
      let plural = NSLocalizedString(many, comment: "Storage size comparison")
      return count == 1 ? single : String(localized: "\(formatCount(count)) \(plural)")
    case let .timesOver(one, name):
      let single = NSLocalizedString(one, comment: "Storage size comparison")
      let named = NSLocalizedString(name, comment: "Storage size comparison")
      let repeats = count == 2
        ? String(localized: "twice over")
        : String(localized: "\(formatCount(count)) times over")
      return count == 1 ? single : String(localized: "\(named), \(repeats)")
    }
  }

  private static func label(for anchor: Anchor, multiplier: Double) -> String {
    let count = max(1, Int(multiplier.rounded(.down)))

    switch anchor.phrasing {
    case let .counted(one, many):
      return count == 1 ? one : "\(formatCount(count)) \(many)"
    case let .timesOver(one, name):
      return count == 1 ? one : "\(name), \(timesOver(count))"
    }
  }

  private static func timesOver(_ count: Int) -> String {
    if count == 2 { return "twice over" }
    guard count < 10 else { return "\(formatCount(count)) times over" }
    let words = NumberFormatter.localizedString(from: NSNumber(value: count), number: .spellOut)
    return "\(words) times over"
  }

  /// Swift's `Hasher` is seeded per process, so the same size would pick a
  /// different anchor on every launch. Mix the bytes by hand instead.
  private static func stableIndex(for bytes: Int64, count: Int) -> Int {
    let mixed = UInt64(bitPattern: bytes) &* 2_654_435_761
    return Int((mixed >> 32) % UInt64(count))
  }

  private static func formatCount(_ count: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
  }
}
