import AppKit
import CoreImage
import SwiftUI

/// A list row icon: a monochrome brand glyph, an installed app's icon drawn in
/// greyscale, or an SF Symbol.
enum BrandRowIcon: Equatable {
    /// A brand silhouette from the bundled Simple Icons set, drawn as a template
    /// so it takes the row's text colour in light and dark alike.
    case glyph(NSImage)
    /// The installed app's own icon, for a brand Simple Icons doesn't carry.
    case appIcon(NSImage)
    case symbol(String)

    static func == (lhs: BrandRowIcon, rhs: BrandRowIcon) -> Bool {
        switch (lhs, rhs) {
        case (.symbol(let a), .symbol(let b)):
            return a == b
        case (.glyph(let a), .glyph(let b)), (.appIcon(let a), .appIcon(let b)):
            return a === b
        default:
            return false
        }
    }
}

/// Resolves row icons for App Caches, Dev Tools and project groups. A known brand
/// gets its monochrome glyph, or its installed app's icon in greyscale when Simple
/// Icons doesn't carry it. Otherwise the definition's `kind` picks an SF Symbol
/// that says what the cache is. Caches Purge doesn't recognise get
/// `questionmark.folder`, so they look different from known ones.
final class BrandIconService {
    static let shared = BrandIconService()

    static let unknownSymbolName = "questionmark.folder"
    static let projectFolderSymbolName = "folder.fill"

    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Fully-resolved row icons, keyed by the row's icon identity.
    ///
    /// `AdaptiveBrandIconImage` resolves inside `body`, and during a scan rows
    /// re-render on every flush, so a resolved icon is kept rather than looked up
    /// again (definition lookups, bundle reads) on the main thread.
    private var rowIconCache: [String: BrandRowIcon] = [:]

    /// Icons for installed `.app` bundles. A miss is kept too, so an app that isn't
    /// installed is not searched for again on every render.
    private var installedAppIconCache: [String: NSImage?] = [:]

    private init() {}

    // MARK: - Public API

    func rowIcon(forCacheItem item: CacheItem) -> BrandRowIcon {
        // Keyed on what resolution actually reads, not on the item: size and timestamps
        // churn constantly during a scan but never change which icon a row gets.
        let key = "c|\(item.definitionKey ?? "")|\(item.bundleID)|\(item.appName)"
        return cachedRowIcon(key: key) {
            let definitionKey = item.definitionKey
                ?? ExplanationDatabase.definitionKey(forFolderName: item.bundleID)
                ?? ExplanationDatabase.definitionKey(forFolderName: item.appName)
            guard let definitionKey else { return .symbol(Self.unknownSymbolName) }
            return icon(forDefinitionKey: definitionKey)
        }
    }

    func rowIcon(forDevTool tool: DevTool) -> BrandRowIcon {
        cachedRowIcon(key: "t|\(tool.definitionKey)") {
            icon(forDefinitionKey: tool.definitionKey)
        }
    }

    func rowIcon(forProjectGroup group: ProjectGroup) -> BrandRowIcon {
        // The dominant artifact can change as sizes land mid-scan, so it belongs in the
        // key rather than being pinned to whatever was largest on first resolve.
        let dominantPath = group.artifacts.max(by: { $0.sizeBytes < $1.sizeBytes })?.path.path ?? ""
        let key = "g|\(dominantPath)|\(group.inferredTypes.map(String.init(describing:)).joined(separator: ","))"
        return cachedRowIcon(key: key) {
            uncachedRowIcon(forProjectGroup: group)
        }
    }

    // MARK: - Resolution

    private func uncachedRowIcon(forProjectGroup group: ProjectGroup) -> BrandRowIcon {
        if let dominant = group.artifacts.max(by: { $0.sizeBytes < $1.sizeBytes }) {
            if let slug = BrandIconMapping.slug(forArtifactKind: dominant.kind),
               let image = brandGlyph(slug: slug) {
                return .glyph(image)
            }
            let pathSlug = BrandIconMapping.slug(forPathComponent: dominant.path.lastPathComponent)
                ?? BrandIconMapping.slug(forPathComponent: dominant.path.path)
            if let pathSlug, let image = brandGlyph(slug: pathSlug) {
                return .glyph(image)
            }
        }
        for type in group.inferredTypes {
            if let slug = BrandIconMapping.slug(forProjectType: type),
               let image = brandGlyph(slug: slug) {
                return .glyph(image)
            }
        }
        // A project really is a folder, so it keeps the folder rather than a kind.
        return .symbol(Self.projectFolderSymbolName)
    }

    private func icon(forDefinitionKey key: String) -> BrandRowIcon {
        if let slug = BrandIconMapping.slug(forDefinitionKey: key),
           let image = brandGlyph(slug: slug) {
            return .glyph(image)
        }
        if let image = installedBrandAppIcon(forDefinitionKey: key) {
            return .appIcon(image)
        }
        if let kind = ExplanationDatabase.kind(forKey: key) {
            return .symbol(kind.symbolName)
        }
        return .symbol(Self.unknownSymbolName)
    }

    private func cachedRowIcon(key: String, resolve: () -> BrandRowIcon) -> BrandRowIcon {
        if let cached = rowIconCache[key] {
            return cached
        }
        let icon = resolve()
        rowIconCache[key] = icon
        return icon
    }

    /// The bundled white silhouette for a Simple Icons slug, marked as a template
    /// so SwiftUI tints it. Generated by `scripts/generate-brand-icons.mjs`.
    func brandGlyph(slug: String) -> NSImage? {
        let cacheKey = slug as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "BrandIcons")
            ?? Bundle.main.url(forResource: slug, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: AppStyle.Row.listIconFrameSize, height: AppStyle.Row.listIconFrameSize)
        image.isTemplate = true
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Cached icon for a known `.app` path. Prefer this over calling
    /// `NSWorkspace.shared.icon(forFile:)` in SwiftUI `body` — non-lazy uninstall
    /// rows re-evaluate often during size updates and sort.
    func installedAppIcon(at url: URL) -> NSImage {
        let path = url.standardizedFileURL.path
        let cacheKey = "p|\(path)"
        if let cached = installedAppIconCache[cacheKey], let image = cached {
            return image
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        installedAppIconCache[cacheKey] = image
        return image
    }

    /// The installed app's icon in greyscale for a brand with no glyph, or nil when
    /// the key isn't one of those brands or the app isn't installed.
    private func installedBrandAppIcon(forDefinitionKey key: String) -> NSImage? {
        guard let appName = BrandIconMapping.applicationName(forDefinitionKey: key) else { return nil }
        let cacheKey = "g|\(key)"
        if let cached = installedAppIconCache[cacheKey] {
            return cached
        }
        let icon = ExplanationDatabase.allBundleIDs(forKey: key).lazy.compactMap(installedAppIcon(bundleID:)).first
            ?? installedAppIcon(appName: appName)
        let image = icon.map(Self.greyscale)
        installedAppIconCache[cacheKey] = image
        return image
    }

    /// Desaturated once here rather than with a SwiftUI filter, which would run on
    /// every render of every row.
    private static func greyscale(_ icon: NSImage) -> NSImage {
        let side = AppStyle.Row.listIconFrameSize
        var rect = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
        let output = CIImage(cgImage: source).applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0]
        )
        guard let image = CIContext().createCGImage(output, from: output.extent) else { return icon }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }

    private func installedAppIcon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        let cacheKey = "b|\(bundleID)"
        if let cached = installedAppIconCache[cacheKey] {
            return cached
        }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        installedAppIconCache[cacheKey] = image
        return image
    }

    private func installedAppIcon(appName: String) -> NSImage? {
        let cacheKey = "n|\(appName)"
        if let cached = installedAppIconCache[cacheKey] {
            return cached
        }
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let image = roots
            .map { ($0 as NSString).appendingPathComponent("\(appName).app") }
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0) }
        installedAppIconCache[cacheKey] = image
        return image
    }
}

/// A row icon: the monochrome brand glyph or the kind's SF Symbol, both in the
/// secondary text colour so light and dark look the same, or an app icon already
/// turned greyscale by the service.
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
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: slotSize, height: slotSize)
        case .glyph(let image):
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: slotSize, height: slotSize)
        case .appIcon(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: slotSize, height: slotSize)
        }
    }

    private var resolved: BrandRowIcon {
        let service = BrandIconService.shared
        switch source {
        case .cacheItem(let item):
            return service.rowIcon(forCacheItem: item)
        case .devTool(let tool):
            return service.rowIcon(forDevTool: tool)
        case .projectGroup(let group):
            return service.rowIcon(forProjectGroup: group)
        case .sfSymbol(let name):
            return .symbol(name)
        }
    }
}
