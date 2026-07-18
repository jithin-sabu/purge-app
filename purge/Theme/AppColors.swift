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

    static let storageBarUsed = Color(light: .hex(0x8A8C96), dark: .hex(0xCACCD6))
    static let storageBarFree = Color(light: .hex(0xD6D7DA), dark: .hex(0x4C4E5A))

    // MARK: - Text

    static let textPrimary = Color(light: .hex(0x1A1B1F), dark: .hex(0xF2F2F3))
    static let textSecondary = Color(light: .hex(0x6B6D76), dark: .hex(0x9A9CA5))
    static let textTertiary = Color(light: .hex(0x9A9CA5), dark: .hex(0x6B6D76))

    // MARK: - Buttons

    static let buttonPrimaryBg = Color(light: .hex(0x1A1B1F), dark: .hex(0xF2F2F3))
    static let buttonPrimaryText = Color(light: .hex(0xFFFFFF), dark: .hex(0x15161A))
    static let buttonSecondaryBorder = Color(light: .hex(0xD6D7DA), dark: .hex(0x3A3B44))

    // MARK: - Safety tags

    static let tagSafeText = Color(light: .hex(0x1A7A43), dark: .hex(0x5FD98A))
    static let tagSafeBg = Color(light: .hex(0xE5F5EB), dark: .hex(0x1B2E22))
    static let tagCheckText = Color(light: .hex(0x9C6300), dark: .hex(0xF2B84B))
    static let tagCheckBg = Color(light: .hex(0xFBEED8), dark: .hex(0x332910))
    static let tagDangerText = Color(light: .hex(0xC5392E), dark: .hex(0xF2685C))
    static let tagDangerBg = Color(light: .hex(0xFBE6E3), dark: .hex(0x321B19))
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
