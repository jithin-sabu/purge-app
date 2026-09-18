import AppKit
import CoreGraphics
import Testing
@testable import Purge

@Suite("Large Files thumbnail fitting")
struct LargeFileThumbnailServiceTests {
    @Test("Oversized QuickLook bitmaps shrink to the row slot")
    func fittedThumbnailDownsamplesLargeBitmaps() throws {
        let source = try makeSolidImage(pixels: 512)
        let fitted = LargeFileThumbnailService.fittedThumbnail(source, pointSize: 28, scale: 2)
        let cg = try #require(fitted.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width <= 56)
        #expect(cg.height <= 56)
        #expect(fitted.size.width == 28)
        #expect(fitted.size.height == 28)
        #expect(LargeFileThumbnailService.pixelCost(of: fitted) <= 56 * 56 * 4)
    }

    @Test("Thumbnails already at slot size are left as-is")
    func fittedThumbnailLeavesSmallImagesAlone() throws {
        let source = try makeSolidImage(pixels: 32)
        let fitted = LargeFileThumbnailService.fittedThumbnail(source, pointSize: 28, scale: 2)
        let cg = try #require(fitted.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 32)
        #expect(cg.height == 32)
    }

    private func makeSolidImage(pixels: Int) throws -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let cgImage = try #require(context.makeImage())
        return NSImage(cgImage: cgImage, size: NSSize(width: pixels, height: pixels))
    }
}
