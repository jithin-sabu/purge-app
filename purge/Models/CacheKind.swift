import Foundation

/// What a cache belongs to, from the `kind` field in `explanations.json`. Rows
/// with no brand glyph show this kind's symbol, so the icon still says what the
/// cache is (an updater, a media cache) instead of showing a generic folder.
enum CacheKind: String, Sendable {
    case updater
    case browser
    case messaging
    case calls
    case ai
    case media
    case photos
    case store
    case design
    case documents
    case cloud
    case code
    case terminal
    case packages
    case build
    case devices
    case logs
    case utilities
    case games
    case system

    var symbolName: String {
        switch self {
        case .updater: "arrow.down.circle"
        case .browser: "globe"
        case .messaging: "bubble.left.and.bubble.right"
        case .calls: "video"
        case .ai: "sparkles"
        case .media: "play.rectangle"
        case .photos: "photo"
        case .store: "bag"
        case .design: "paintbrush.pointed"
        case .documents: "doc.text"
        case .cloud: "icloud"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .packages: "shippingbox"
        case .build: "hammer"
        case .devices: "iphone"
        case .logs: "list.bullet.rectangle"
        case .utilities: "wrench.and.screwdriver"
        case .games: "gamecontroller"
        case .system: "gearshape"
        }
    }
}
