import Foundation

/// Size anchors drawn from famous digital artifacts, phrased as multipliers
/// ("82× the original DOOM") rather than unit conversions ("13 hours of 4K
/// video"). The anchors are things people know *as software or data*, and
/// most are famous for being tiny or old, so the multiplier carries the joke.
///
/// Because every anchor scales by a multiplier, a handful of KB–GB anchors
/// covers everything from a small cache sweep to a multi-terabyte lifetime
/// total — no separate "huge" anchors needed.
enum SizeComparisonCatalog {
  enum Phrasing {
    /// "82× the original DOOM" — for singular, non-countable works.
    case multiplier(String)
    /// "19 CDs" — for objects you'd naturally count. Always plural, since a
    /// comparison only ever surfaces at a multiplier of 2 or more.
    case counted(plural: String)
  }

  struct Anchor {
    let bytes: Int64
    let symbol: String
    let phrasing: Phrasing
  }

  private static let kb: Int64 = 1024
  private static let mb: Int64 = 1024 * 1024
  private static let gb: Int64 = 1024 * 1024 * 1024

  /// A multiplier below this reads as a rounding error rather than a flex.
  private static let minMultiplier = 2.0
  /// Past this, the number stops meaning anything.
  private static let maxMultiplier = 20_000.0
  /// Multipliers near this feel most quotable — big enough to impress,
  /// small enough to picture.
  private static let idealMultiplier = 25.0
  /// How much worse than the best fit an anchor may score and still be a
  /// candidate, in log10 units — roughly "within a factor of two as far off".
  private static let scoreTolerance = 0.3

  static let anchors: [Anchor] = [
    Anchor(
      bytes: 40 * kb, symbol: "gamecontroller.fill",
      phrasing: .multiplier("Super Mario Bros.")
    ),
    Anchor(
      bytes: 72 * kb, symbol: "moon.stars.fill",
      phrasing: .multiplier("the Apollo 11 code")
    ),
    Anchor(
      bytes: 128 * kb, symbol: "desktopcomputer",
      phrasing: .multiplier("the first Mac's memory")
    ),
    Anchor(
      bytes: 1 * mb, symbol: "gamecontroller.fill",
      phrasing: .multiplier("Pokémon Red")
    ),
    Anchor(
      bytes: 1_440 * kb, symbol: "externaldrive.fill",
      phrasing: .counted(plural: "floppy disks")
    ),
    Anchor(
      bytes: (24 * mb) / 10, symbol: "flame.fill",
      phrasing: .multiplier("the original DOOM")
    ),
    Anchor(
      bytes: (375 * mb) / 100, symbol: "internaldrive.fill",
      phrasing: .multiplier("the first hard drive")
    ),
    Anchor(
      bytes: 5 * mb, symbol: "book.closed.fill",
      phrasing: .multiplier("all of Shakespeare")
    ),
    Anchor(
      bytes: 40 * mb, symbol: "macwindow",
      phrasing: .multiplier("Windows 95")
    ),
    Anchor(
      bytes: 700 * mb, symbol: "opticaldisc",
      phrasing: .counted(plural: "CDs")
    ),
    Anchor(
      bytes: 750 * mb, symbol: "atom",
      phrasing: .multiplier("the human genome")
    ),
    Anchor(
      bytes: 4 * gb, symbol: "iphone",
      phrasing: .multiplier("the first iPhone")
    ),
    Anchor(
      bytes: (47 * gb) / 10, symbol: "opticaldisc",
      phrasing: .counted(plural: "DVDs")
    ),
    Anchor(
      bytes: 5 * gb, symbol: "music.note",
      phrasing: .multiplier("the first iPod")
    ),
    Anchor(
      bytes: 22 * gb, symbol: "text.book.closed.fill",
      phrasing: .multiplier("the English Wikipedia")
    ),
  ]

  /// Picks the anchor whose multiplier lands closest to `idealMultiplier` on a
  /// log scale, so the phrasing stays quotable at any size. Among the closest
  /// few, the byte count itself selects one — deterministic (the same size
  /// always yields the same line) but varied across different sizes.
  static func item(for bytes: Int64) -> OnboardingSizeComparisonItem? {
    guard bytes > 0 else { return nil }

    let scored = anchors.compactMap { anchor -> (anchor: Anchor, multiplier: Double, score: Double)? in
      let multiplier = Double(bytes) / Double(anchor.bytes)
      guard multiplier >= minMultiplier, multiplier <= maxMultiplier else { return nil }
      return (anchor, multiplier, abs(log10(multiplier) - log10(idealMultiplier)))
    }

    guard let best = scored.min(by: { $0.score < $1.score }) else { return nil }

    // Vary only among anchors that fit about as well as the best one, so
    // picking for variety never costs a noticeably more quotable number.
    let bestFits = Array(
      scored
        .filter { $0.score <= best.score + scoreTolerance }
        .sorted { $0.score < $1.score }
        .prefix(3)
    )
    let pick = bestFits[stableIndex(for: bytes, count: bestFits.count)]

    return OnboardingSizeComparisonItem(
      symbol: pick.anchor.symbol,
      label: label(for: pick.anchor, multiplier: pick.multiplier)
    )
  }

  private static func label(for anchor: Anchor, multiplier: Double) -> String {
    let count = max(2, Int(multiplier.rounded()))

    switch anchor.phrasing {
    case let .multiplier(name):
      return "\(formatCount(count))× \(name)"
    case let .counted(plural):
      return "\(formatCount(count)) \(plural)"
    }
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
