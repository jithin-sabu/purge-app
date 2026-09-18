import AppKit
import CoreGraphics
@preconcurrency import QuickLookThumbnailing

/// Generates and caches QuickLook thumbnails for the Large Files list.
///
/// Thumbnails are produced off the main thread via `QLThumbnailGenerator` (covering images,
/// video frames, PDFs, and anything else QuickLook supports) and kept in an in-memory
/// `NSCache` keyed by file path + modification date. The cache lets re-scrolling the list — or
/// returning to the screen — reuse work already done this session. Count and byte cost limits
/// keep it from holding decoded bitmaps QuickLook sometimes returns far larger than the 28pt
/// row slot. Swift task cancellation cancels the underlying QuickLook request, so rows that
/// scroll off-screen before completion don't waste work.
///
/// Scoped to the Large Files feature; nothing else in the app uses this.
final class LargeFileThumbnailService: @unchecked Sendable {
    static let shared = LargeFileThumbnailService()

    /// Byte budget for decoded thumbnails. 500 full-size QuickLook images blew past this
    /// on a Large Files visit; the row still draws at `listIconFrameSize`, so extras are
    /// only RAM.
    static let totalCostLimit = 24 * 1024 * 1024
    static let countLimit = 500

    private let generator = QLThumbnailGenerator.shared

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        return cache
    }()

    private let memoryPressureSource: DispatchSourceMemoryPressure

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            self?.cache.removeAllObjects()
        }
        source.resume()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    /// A stable cache key combining the file path with its last-touched time, so an edited
    /// file regenerates its thumbnail rather than serving a stale one.
    static func cacheKey(path: String, modified: Date) -> String {
        "\(path)|\(modified.timeIntervalSinceReferenceDate)"
    }

    /// Returns an already-generated thumbnail without touching disk, if one is cached.
    func cachedThumbnail(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// Generates a thumbnail off the main thread, returning `nil` when QuickLook can't produce
    /// one (unsupported type, corrupt file, or a generation error). Honors Swift task
    /// cancellation by cancelling the in-flight QuickLook request.
    func thumbnail(for url: URL, key: String, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSize, height: pointSize),
            scale: max(scale, 1),
            representationTypes: .thumbnail
        )

        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                generator.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.nsImage)
                }
            }
        } onCancel: {
            generator.cancel(request)
        }

        guard let image else { return nil }
        let fitted = Self.fittedThumbnail(image, pointSize: pointSize, scale: scale)
        cache.setObject(fitted, forKey: key as NSString, cost: Self.pixelCost(of: fitted))
        return fitted
    }

    /// Draws `image` into a bitmap no larger than the row slot in pixels. QuickLook often
    /// returns a much larger representation than requested; SwiftUI would scale it down in
    /// the 28pt frame, so the on-screen result is unchanged.
    static func fittedThumbnail(_ image: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let pixel = max(Int((pointSize * max(scale, 1)).rounded()), 1)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        if cgImage.width <= pixel && cgImage.height <= pixel {
            return image
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixel,
            height: pixel,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high

        let srcWidth = CGFloat(cgImage.width)
        let srcHeight = CGFloat(cgImage.height)
        let fill = max(CGFloat(pixel) / srcWidth, CGFloat(pixel) / srcHeight)
        let drawWidth = srcWidth * fill
        let drawHeight = srcHeight * fill
        let drawRect = CGRect(
            x: (CGFloat(pixel) - drawWidth) / 2,
            y: (CGFloat(pixel) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        context.draw(cgImage, in: drawRect)
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: NSSize(width: pointSize, height: pointSize))
    }

    static func pixelCost(of image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 1
        }
        return max(cgImage.width * cgImage.height * 4, 1)
    }
}
