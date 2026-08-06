import AppKit
import SwiftUI

/// Light/dark appearance for resolving bundled simple-icons assets.
enum BrandIconAppearance: Equatable, Sendable {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }

    init(nsAppearance: NSAppearance) {
        let match = nsAppearance.bestMatch(from: [.darkAqua, .aqua])
        self = match == .darkAqua ? .dark : .light
    }

    static var current: BrandIconAppearance {
        BrandIconAppearance(nsAppearance: NSApp.effectiveAppearance)
    }
}

/// A list row icon: brand bitmap or an SF Symbol at native proportions.
enum BrandRowIcon: Equatable {
    case bitmap(NSImage)
    case symbol(String)

    static func == (lhs: BrandRowIcon, rhs: BrandRowIcon) -> Bool {
        switch (lhs, rhs) {
        case (.symbol(let a), .symbol(let b)):
            return a == b
        case (.bitmap, .bitmap):
            return false
        default:
            return false
        }
    }
}

/// Resolves row icons for App Caches and Dev Tools from bundled simple-icons PNGs,
/// installed application bundles, or the `folder.fill` SF Symbol fallback.
final class BrandIconService {
    static let shared = BrandIconService()

    static let fallbackFolderSymbolName = "folder.fill"

    private let imageCache = NSCache<NSString, NSImage>()

    /// Fully-resolved row icons, keyed by the row's icon identity plus appearance.
    ///
    /// Resolution is not cheap: a miss walks the bundled-asset lookup, then Launch
    /// Services, then up to nine `fileExists` probes. `AdaptiveBrandIconImage` resolves
    /// inside `body`, so without this every re-render of a visible row repeated that
    /// work on the main thread — and during a scan the rows re-render on every flush.
    private var rowIconCache: [String: BrandRowIcon] = [:]

    /// Installed-app lookups, **including misses** (`nil`). The miss is the expensive
    /// case — it is the one that runs the full nine-probe filesystem walk and finds
    /// nothing — so caching only hits would leave the hot path uncached.
    private var installedAppIconCache: [String: NSImage?] = [:]

    private init() {}

    // MARK: - Public API

    func rowIcon(forCacheItem item: CacheItem, appearance: BrandIconAppearance) -> BrandRowIcon {
        // Keyed on what resolution actually reads, not on the item: size and timestamps
        // churn constantly during a scan but never change which icon a row gets.
        let key = "c|\(appearance)|\(item.definitionKey ?? "")|\(item.bundleID)|\(item.appName)"
        return cachedRowIcon(key: key) {
            if let key = item.definitionKey, let image = resolve(definitionKey: key, appearance: appearance) {
                return .bitmap(image)
            }
            if let key = ExplanationDatabase.definitionKey(forFolderName: item.bundleID),
               let image = resolve(definitionKey: key, appearance: appearance) {
                return .bitmap(image)
            }
            if let image = resolve(appName: item.appName, bundleID: item.bundleID, appearance: appearance) {
                return .bitmap(image)
            }
            return .symbol(Self.fallbackFolderSymbolName)
        }
    }

    func rowIcon(forCacheItem item: CacheItem, colorScheme: ColorScheme) -> BrandRowIcon {
        rowIcon(forCacheItem: item, appearance: BrandIconAppearance(colorScheme: colorScheme))
    }

    func rowIcon(forDevTool tool: DevTool, appearance: BrandIconAppearance) -> BrandRowIcon {
        cachedRowIcon(key: "t|\(appearance)|\(tool.definitionKey)") {
            if let image = resolve(definitionKey: tool.definitionKey, appearance: appearance) {
                return .bitmap(image)
            }
            return .symbol(Self.fallbackFolderSymbolName)
        }
    }

    func rowIcon(forDevTool tool: DevTool, colorScheme: ColorScheme) -> BrandRowIcon {
        rowIcon(forDevTool: tool, appearance: BrandIconAppearance(colorScheme: colorScheme))
    }

    func rowIcon(forProjectGroup group: ProjectGroup, appearance: BrandIconAppearance) -> BrandRowIcon {
        // The dominant artifact can change as sizes land mid-scan, so it belongs in the
        // key rather than being pinned to whatever was largest on first resolve.
        let dominantPath = group.artifacts.max(by: { $0.sizeBytes < $1.sizeBytes })?.path.path ?? ""
        let key = "g|\(appearance)|\(dominantPath)|\(group.inferredTypes.map(String.init(describing:)).joined(separator: ","))"
        return cachedRowIcon(key: key) {
            uncachedRowIcon(forProjectGroup: group, appearance: appearance)
        }
    }

    private func uncachedRowIcon(forProjectGroup group: ProjectGroup, appearance: BrandIconAppearance) -> BrandRowIcon {
        if let dominant = group.artifacts.max(by: { $0.sizeBytes < $1.sizeBytes }) {
            if let slug = BrandIconMapping.slug(forArtifactKind: dominant.kind),
               let image = bundledBrandImage(slug: slug, appearance: appearance) {
                return .bitmap(image)
            }
            let pathSlug = BrandIconMapping.slug(forPathComponent: dominant.path.lastPathComponent)
                ?? BrandIconMapping.slug(forPathComponent: dominant.path.path)
            if let pathSlug, let image = bundledBrandImage(slug: pathSlug, appearance: appearance) {
                return .bitmap(image)
            }
        }
        if let image = iconForProjectTypes(group.inferredTypes, appearance: appearance) {
            return .bitmap(image)
        }
        return .symbol(Self.fallbackFolderSymbolName)
    }

    func rowIcon(forProjectGroup group: ProjectGroup, colorScheme: ColorScheme) -> BrandRowIcon {
        rowIcon(forProjectGroup: group, appearance: BrandIconAppearance(colorScheme: colorScheme))
    }

    // MARK: - Resolution

    private func cachedRowIcon(key: String, resolve: () -> BrandRowIcon) -> BrandRowIcon {
        if let cached = rowIconCache[key] {
            return cached
        }
        let icon = resolve()
        rowIconCache[key] = icon
        return icon
    }

    private func resolve(definitionKey key: String, appearance: BrandIconAppearance) -> NSImage? {
        if !BrandIconMapping.isBundleOnlyDefinitionKey(key),
           let slug = BrandIconMapping.slug(forDefinitionKey: key),
           let image = bundledBrandImage(slug: slug, appearance: appearance) {
            return image
        }
        if let bundleImage = bundleIcon(forDefinitionKey: key) {
            return bundleImage
        }
        if let appName = BrandIconMapping.preferredApplicationName(forDefinitionKey: key),
           let image = installedAppIcon(appName: appName) {
            return image
        }
        if let slug = BrandIconMapping.slug(forDefinitionKey: key),
           let image = bundledBrandImage(slug: slug, appearance: appearance) {
            return image
        }
        return nil
    }

    private func resolve(appName: String, bundleID: String, appearance: BrandIconAppearance) -> NSImage? {
        if let key = ExplanationDatabase.definitionKey(forFolderName: appName),
           let image = resolve(definitionKey: key, appearance: appearance) {
            return image
        }
        if let image = installedAppIcon(bundleID: bundleID) {
            return image
        }
        if let image = installedAppIcon(appName: appName) {
            return image
        }
        return nil
    }

    private func iconForProjectTypes(_ types: [ProjectType], appearance: BrandIconAppearance) -> NSImage? {
        for type in types {
            if let slug = BrandIconMapping.slug(forProjectType: type),
               let image = bundledBrandImage(slug: slug, appearance: appearance) {
                return image
            }
        }
        return nil
    }

    private func bundleIcon(forDefinitionKey key: String) -> NSImage? {
        if let bundleID = BrandIconMapping.preferredBundleID(forDefinitionKey: key),
           let image = installedAppIcon(bundleID: bundleID) {
            return image
        }
        for bundleID in ExplanationDatabase.allBundleIDs(forKey: key) {
            if let image = installedAppIcon(bundleID: bundleID) {
                return image
            }
        }
        return nil
    }

    func bundledBrandImage(slug: String, appearance: BrandIconAppearance) -> NSImage? {
        let resourceName = appearance == .dark ? "\(slug)-dark" : slug
        let cacheKey = "\(resourceName)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        var url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "BrandIcons"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: "png")
        if url == nil, appearance == .dark {
            url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "BrandIcons")
                ?? Bundle.main.url(forResource: slug, withExtension: "png")
        }
        guard let url else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: AppStyle.Row.listIconFrameSize, height: AppStyle.Row.listIconFrameSize)
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func installedAppIcon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        let cacheKey = "b|\(bundleID)"
        if let cached = installedAppIconCache[cacheKey] {
            return cached
        }
        var image: NSImage?
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        installedAppIconCache[cacheKey] = image
        return image
    }

    func installedAppIcon(appName: String) -> NSImage? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cacheKey = "n|\(trimmed)"
        if let cached = installedAppIconCache[cacheKey] {
            return cached
        }
        let image = uncachedInstalledAppIcon(trimmedAppName: trimmed)
        installedAppIconCache[cacheKey] = image
        return image
    }

    private func uncachedInstalledAppIcon(trimmedAppName trimmed: String) -> NSImage? {
        var candidates = [trimmed]
        if !trimmed.hasSuffix(".app") {
            candidates.append("\(trimmed).app")
        }
        if trimmed.contains(" ") {
            candidates.append(trimmed.replacingOccurrences(of: " ", with: "") + ".app")
        }

        let searchRoots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ]

        for root in searchRoots {
            for name in candidates {
                let path = (root as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path) {
                    return NSWorkspace.shared.icon(forFile: path)
                }
            }
        }
        return nil
    }
}

/// SwiftUI brand icon that re-resolves when the system color scheme changes.
struct AdaptiveBrandIconImage: View {
    enum Source: Equatable {
        case cacheItem(CacheItem)
        case devTool(DevTool)
        case projectGroup(ProjectGroup)
        case sfSymbol(String)
    }

    let source: Source
    /// When set, forces a square slot for alignment (e.g. project group headers).
    var squareSize: CGFloat?
    var cornerRadius: CGFloat = 6

    @Environment(\.colorScheme) private var colorScheme

    private var slotSize: CGFloat {
        squareSize ?? AppStyle.Row.listIconFrameSize
    }

    private var symbolPointSize: CGFloat {
        AppStyle.Row.sfSymbolPointSize * (slotSize / AppStyle.Row.listIconFrameSize)
    }

    var body: some View {
        switch resolved {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: symbolPointSize))
                .foregroundStyle(.secondary)
                .frame(width: slotSize, height: slotSize)
        case .bitmap(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: slotSize, height: slotSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private var resolved: BrandRowIcon {
        let service = BrandIconService.shared
        switch source {
        case .cacheItem(let item):
            return service.rowIcon(forCacheItem: item, colorScheme: colorScheme)
        case .devTool(let tool):
            return service.rowIcon(forDevTool: tool, colorScheme: colorScheme)
        case .projectGroup(let group):
            return service.rowIcon(forProjectGroup: group, colorScheme: colorScheme)
        case .sfSymbol(let name):
            return .symbol(name)
        }
    }
}
