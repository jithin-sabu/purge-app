import Foundation

enum SpaceContextTranslation {
  static func phrase(for bytes: Int64) -> String {
    guard bytes > 0 else {
      return "Your Mac has a little more breathing room."
    }
    let photos = max(1, Int((Double(bytes) / Double(MediaSizeReference.bytesPerPhoto)).rounded()))
    let formatted = NumberFormatter.localizedString(from: NSNumber(value: photos), number: .decimal)
    if photos == 1 {
      return "That's about \(formatted) photo's worth of space."
    }
    return "That's about \(formatted) photos' worth of space."
  }
}
