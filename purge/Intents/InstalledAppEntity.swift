import AppIntents
import AppKit

/// An installed app, as the uninstaller lists it. The id is the bundle path,
/// the same value as `InstalledApp.id`, so it drops straight into the
/// uninstaller's selection.
struct InstalledAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = InstalledAppQuery()

    let id: String
    let name: String
    let bundleID: String?
    /// The app's own icon as PNG. Without it Spotlight shows Purge's icon on
    /// every row.
    let iconPNG: Data?

    init(_ app: AppUninstallScanner.DiscoveredApp, iconPNG: Data? = nil) {
        id = app.bundleURL.standardizedFileURL.path
        name = app.name
        bundleID = app.bundleID
        self.iconPNG = iconPNG
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: bundleID.map { "\($0)" },
            image: iconPNG.map { DisplayRepresentation.Image(data: $0) }
        )
    }
}

/// Finds apps for the picker and for Spotlight, from the uninstaller's own
/// index. `@concurrent` keeps the folder reads off the main thread.
struct InstalledAppQuery: EntityStringQuery {
    @concurrent
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let wanted = Set(identifiers)
        return await InstalledAppIndex.shared.apps().filter { wanted.contains($0.id) }
    }

    @concurrent
    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        InstalledAppIndex.matching(string, in: await InstalledAppIndex.shared.apps())
    }

    @concurrent
    func suggestedEntities() async throws -> [InstalledAppEntity] {
        await InstalledAppIndex.shared.apps()
    }
}

/// Holds the app list for a few seconds. Spotlight asks again on every
/// keystroke, and reading a couple of hundred Info.plists each time adds up.
actor InstalledAppIndex {
    static let shared = InstalledAppIndex()

    private var cached: [InstalledAppEntity] = []
    private var cachedAt: Date?
    private let lifetime: TimeInterval = 30
    /// Icons outlive the list: they rarely change, and drawing a couple of
    /// hundred of them is the slow part.
    private var iconsByPath: [String: Data] = [:]

    func apps(now: Date = Date()) -> [InstalledAppEntity] {
        if let cachedAt, now.timeIntervalSince(cachedAt) < lifetime {
            return cached
        }
        cached = AppUninstallScanner.discoverInstalledApps()
            .map { InstalledAppEntity($0, iconPNG: icon(for: $0.bundleURL)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedAt = now
        return cached
    }

    private func icon(for bundleURL: URL) -> Data? {
        let path = bundleURL.standardizedFileURL.path
        if let icon = iconsByPath[path] { return icon }
        let icon = Self.iconPNG(atPath: path)
        iconsByPath[path] = icon
        return icon
    }

    /// 64 px, enough for a Spotlight row at 2x and small to send per keystroke.
    /// Drawn into its own bitmap: `cgImage(forProposedRect:)` alone can hand back
    /// a larger representation.
    static func iconPNG(atPath path: String, side: Int = 64) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Matches the way the uninstaller's search box does: name or bundle id.
    nonisolated static func matching(_ text: String, in apps: [InstalledAppEntity]) -> [InstalledAppEntity] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query)
                || ($0.bundleID?.lowercased().contains(query) ?? false)
        }
    }
}
