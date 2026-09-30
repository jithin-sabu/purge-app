import AppKit
import SwiftUI

enum AppColors {
    // MARK: - Surfaces

    static let bgBase = Color(light: .hex(0xF5F5F6), dark: .hex(0x15161A))
    static let bgCard = Color(light: .hex(0xFFFFFF), dark: .hex(0x1C1D22))
    static let bgElevated = Color(light: .hex(0xECEDEF), dark: .hex(0x23242B))
    static let bgOverlay = Color(light: .hex(0xFFFFFF), dark: .hex(0x2A2B33))
    static let borderSubtle = Color(light: .hex(0xE2E3E6), dark: .hex(0x2E2F37))

    // MARK: - Storage bar

    static let storageBarFree = Color(light: .hex(0xD6D7DA), dark: .hex(0x4C4E5A))

    // MARK: - Overview categories

    // The Okabe–Ito palette, made to stay distinct with any kind of color blindness:
    // sky blue, blue, orange, vermillion, reddish purple. Light mode uses the
    // published values; dark mode lifts each a little so it holds up on the dark card.
    // Neighbours on the bar differ in lightness as well as hue.
    static let overviewAppCaches = Color(light: .hex(0x56B4E9), dark: .hex(0x6CC3F0))
    static let overviewDevTools = Color(light: .hex(0x0072B2), dark: .hex(0x3A94D0))
    static let overviewLargeFiles = Color(light: .hex(0xE69F00), dark: .hex(0xF0B020))
    static let overviewApps = Color(light: .hex(0xD55E00), dark: .hex(0xE8772A))
    static let overviewLeftovers = Color(light: .hex(0xCC79A7), dark: .hex(0xDA93BA))
    /// Icon tiles carry a white glyph, which the pale sky blue and pink can't hold,
    /// so those two tiles use a deeper shade than their bar segment. Dev Tools goes
    /// deeper too in dark mode, so its tile stays apart from the App Caches one.
    static let overviewAppCachesTile = Color(light: .hex(0x3399D3), dark: .hex(0x3A9BD5))
    static let overviewDevToolsTile = Color(light: .hex(0x0072B2), dark: .hex(0x1E78BA))
    static let overviewLeftoversTile = Color(light: .hex(0xB35A8D), dark: .hex(0xBE6C9C))
    /// Close to the sidebar's "used" grey, and well apart from free space in both themes.
    static let overviewEverythingElse = Color(light: .hex(0x8A8C96), dark: .hex(0xA3A6B4))

    // MARK: - Text

    static let textPrimary = Color(light: .hex(0x1A1B1F), dark: .hex(0xF2F2F3))
    static let textSecondary = Color(light: .hex(0x6B6D76), dark: .hex(0x9A9CA5))
    static let textTertiary = Color(light: .hex(0x9A9CA5), dark: .hex(0x6B6D76))

    // MARK: - Buttons

    static let buttonPrimaryBg = Color(light: .hex(0x1A1B1F), dark: .hex(0xF2F2F3))
    static let buttonPrimaryText = Color(light: .hex(0xFFFFFF), dark: .hex(0x15161A))
    static let buttonSecondaryBorder = Color(light: .hex(0xD6D7DA), dark: .hex(0x3A3B44))

    // MARK: - Safety tags

    static let tagSafeText = Color(light: .hex(0x34C759), dark: .hex(0x63D86D))
    static let tagSafeBg = Color(light: .hex(0xE5F5EB), dark: .hex(0x1B2E22))
    static let tagCheckText = Color(light: .hex(0x9C6300), dark: .hex(0xF2B84B))
    static let tagCheckBg = Color(light: .hex(0xFBEED8), dark: .hex(0x332910))
    static let tagDangerText = Color(light: .hex(0xC5392E), dark: .hex(0xF2685C))
    static let tagDangerBg = Color(light: .hex(0xFBE6E3), dark: .hex(0x321B19))
    /// Bright, saturated red for a solid destructive button fill (white text on
    /// top). The muted `tagDangerText` reads salmon-pale as a fill on dark.
    static let destructiveFill = Color(light: .hex(0xE5322A), dark: .hex(0xFF3B30))
    static let tagUnsureText = Color(light: .hex(0x5C5E66), dark: .hex(0xA7A9B2))
    static let tagUnsureBg = Color(light: .hex(0xEDEDEF), dark: .hex(0x26272D))

    /// AppKit checkbox / control accent (matches `buttonPrimaryBg`).
    static var controlAccentNSColor: NSColor {
        NSColor(name: "AppColorsControlAccent") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .hex(0xF2F2F3)
                : .hex(0x1A1B1F)
        }
    }
}

private extension NSColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        })
    }
}
