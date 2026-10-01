import AppKit
import SwiftUI

/// Every colour in the app. Tokens are named by job (text, surface, fill,
/// border, action, status, chart) so the name says where a colour belongs.
/// Views pick one of these instead of raw hex or SwiftUI's `.secondary` greys.
/// Plain white and black are only for shadows, masks, and glyphs on coloured
/// tiles. Values and contrast notes live in docs/design-system.md.
enum AppColors {
    // MARK: - Text

    /// Body text and titles. Charcoal, not black: 13.6:1 on a light card.
    static let textPrimary = Color(light: 0x2C2E35, dark: 0xE9EAED)
    /// Supporting text: metadata, captions, idle sidebar items. 6:1 or better.
    static let textSecondary = Color(light: 0x61636C, dark: 0xA1A3AC)
    /// Icons, chevrons, placeholders and timestamps. Never a sentence someone
    /// has to read (3.8:1 light, 4.2:1 dark).
    static let textTertiary = Color(light: 0x80828C, dark: 0x7D7F89)

    // MARK: - Surfaces

    /// The window background.
    static let surfaceBase = Color(light: 0xF6F6F8, dark: 0x15161A)
    /// Grouped content: cards, lists, sheets.
    static let surfaceCard = Color(light: 0xFFFFFF, dark: 0x1C1D22)
    /// One step above whatever it sits on: menus, dropdowns, pickers, and the
    /// hover on the window background.
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x2A2B33)
    /// A hovered or selected row on a card. (Rows used `surfaceRaised` before,
    /// which is white on a white card in light mode, so hover never showed.)
    static let surfaceCardHover = Color(light: 0xF2F3F5, dark: 0x2A2B33)

    // MARK: - Fills

    /// Secondary button fill, selected sidebar item, search fields, tracks.
    static let fillSecondary = Color(light: 0xEEEFF2, dark: 0x26272E)
    static let fillSecondaryHover = Color(light: 0xE7E8EC, dark: 0x2D2E36)
    static let fillSecondaryPressed = Color(light: 0xDFE0E5, dark: 0x34353E)

    // MARK: - Borders

    static let borderSubtle = Color(light: 0xE4E5E9, dark: 0x2E2F37)
    /// Borders that outline a control: secondary buttons, pickers, checkboxes.
    static let borderStrong = Color(light: 0xD3D5DA, dark: 0x3A3B44)

    // MARK: - Actions

    /// The one main action on a screen. Also the checkbox and focus accent.
    static let actionPrimary = Color(nsColor: actionPrimaryNSColor)
    static let actionPrimaryHover = Color(light: 0x40424B, dark: 0xF4F5F7)
    static let actionPrimaryPressed = Color(light: 0x2A2C32, dark: 0xD5D6DA)
    /// Label colour on top of `actionPrimary`.
    static let onActionPrimary = Color(light: 0xFFFFFF, dark: 0x15161A)
    /// Solid fill for confirming a move to Trash. White label on top.
    static let actionDestructive = Color(light: 0xD1312A, dark: 0xD9372D)
    static let actionDestructiveHover = Color(light: 0xBC2B25, dark: 0xE2453B)
    static let actionDestructivePressed = Color(light: 0xA92620, dark: 0xC4302A)

    // MARK: - Status

    static let statusSafeText = Color(light: 0x1F7A35, dark: 0x5FD36B)
    static let statusSafeFill = Color(light: 0xE6F4EA, dark: 0x1B2E22)
    static let statusCheckText = Color(light: 0x8A5300, dark: 0xF2B84B)
    static let statusCheckFill = Color(light: 0xFAEEDA, dark: 0x332910)
    static let statusDangerText = Color(light: 0xB4302A, dark: 0xF47468)
    static let statusDangerFill = Color(light: 0xFBE8E5, dark: 0x321B19)
    static let statusUnsureText = Color(light: 0x565861, dark: 0xA7A9B2)
    static let statusUnsureFill = Color(light: 0xEEEEF1, dark: 0x26272D)

    // MARK: - Overlays

    /// The dimming layer behind the cleanup celebration while it fades in. The
    /// celebration itself forces dark mode and draws on `surfaceBase`, so its
    /// text and buttons use the ordinary dark-mode tokens.
    static let scrim = Color.black.opacity(0.38)

    // MARK: - Accent

    /// The time highlight on the cleanup celebration.
    static let accentCelebrate = Color(light: 0xFFC70D, dark: 0xFFC70D)

    // MARK: - Charts

    /// The Overview breakdown. The Okabe–Ito palette, made to stay distinct with
    /// any kind of color blindness: sky blue, blue, orange, vermillion, reddish
    /// purple. Light mode uses the published values; dark mode lifts each a
    /// little so it holds up on the dark card. Neighbours on the bar differ in
    /// lightness as well as hue.
    enum Chart {
        static let appCaches = Color(light: 0x56B4E9, dark: 0x6CC3F0)
        static let devTools = Color(light: 0x0072B2, dark: 0x3A94D0)
        static let largeFiles = Color(light: 0xE69F00, dark: 0xF0B020)
        static let apps = Color(light: 0xD55E00, dark: 0xE8772A)
        static let leftovers = Color(light: 0xCC79A7, dark: 0xDA93BA)
        /// Icon tiles carry a white glyph, which the pale sky blue and pink can't
        /// hold, so those two tiles use a deeper shade than their bar segment.
        /// Dev Tools goes deeper too in dark mode, so its tile stays apart from
        /// the App Caches one.
        static let appCachesTile = Color(light: 0x3399D3, dark: 0x3A9BD5)
        static let devToolsTile = Color(light: 0x0072B2, dark: 0x1E78BA)
        static let leftoversTile = Color(light: 0xB35A8D, dark: 0xBE6C9C)
        /// Close to the sidebar's "used" grey, and well apart from free space in
        /// both themes.
        static let everythingElse = Color(light: 0x8A8C96, dark: 0xA3A6B4)
        /// Free space on the storage bars.
        static let freeSpace = Color(light: 0xD6D7DA, dark: 0x4C4E5A)
    }

    // MARK: - AppKit

    /// AppKit checkbox / control accent, the same colour as `actionPrimary`.
    static var controlAccentNSColor: NSColor { actionPrimaryNSColor }

    private static let actionPrimaryNSColor = NSColor(light: 0x34363E, dark: 0xE9EAED)
}

private extension NSColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    convenience init(light: UInt32, dark: UInt32) {
        let light = NSColor.hex(light)
        let dark = NSColor.hex(dark)
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
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

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(light: light, dark: dark))
    }
}
