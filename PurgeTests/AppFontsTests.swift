import CoreText
import Foundation
import Testing
@testable import Purge

/// Onest is registered from a copy that outlives the bundle (2026-10-24: a
/// running build lost its bundle and every label fell back to the system font).
@MainActor
struct AppFontsTests {
    @Test func registersOnestWithItsWeights() {
        #expect(AppFonts.register())
        for (weight, expected) in [(0.0, "Onest-Regular"), (0.23, "Onest-Medium"), (0.3, "Onest-SemiBold"), (0.4, "Onest-Bold")] {
            let attributes: [CFString: Any] = [
                kCTFontFamilyNameAttribute: "Onest",
                kCTFontTraitsAttribute: [kCTFontWeightTrait: weight] as CFDictionary,
            ]
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), 13, nil)
            #expect(CTFontCopyPostScriptName(font) as String == expected)
        }
    }

    @Test func stableCopyWritesOnceAndRefreshesWhenTheBundledFileChanges() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFontsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source", isDirectory: true).appendingPathComponent("OnestText.ttf")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source)
        let fonts = folder.appendingPathComponent("Fonts", isDirectory: true)

        let copy = try #require(AppFonts.stableCopy(of: source, in: fonts))
        #expect(copy == fonts.appendingPathComponent("OnestText.ttf"))
        #expect(try Data(contentsOf: copy) == Data("first".utf8))

        let firstWrite = try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
        #expect(AppFonts.stableCopy(of: source, in: fonts) == copy)
        let secondWrite = try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
        #expect(firstWrite == secondWrite, "an unchanged font was written again")

        try Data("second".utf8).write(to: source)
        #expect(AppFonts.stableCopy(of: source, in: fonts) == copy)
        #expect(try Data(contentsOf: copy) == Data("second".utf8))
    }

    @Test func stableCopyGivesUpWithoutASource() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("AppFontsTests-missing.ttf")
        let fonts = FileManager.default.temporaryDirectory.appendingPathComponent("AppFontsTests-\(UUID().uuidString)", isDirectory: true)
        #expect(AppFonts.stableCopy(of: missing, in: fonts) == nil)
        #expect(!FileManager.default.fileExists(atPath: fonts.path))
    }
}
