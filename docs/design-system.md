# Purge design system

Every colour, button, font and radius in Purge comes from three files:

- `purge/Theme/AppColors.swift`: colours
- `purge/Views/AppStyle.swift`: type scale, radii, spacing, row metrics
- `purge/Views/PurgeButtonStyle.swift`: the one button style

`node scripts/lint-design-tokens.mjs` (also `npm run lint:design`, and a CI step) fails when a view uses a raw colour, a SwiftUI grey like `.secondary`, a point size or text style on text, a literal corner radius, a hex colour outside the theme file, or a removed button style. Add `design-lint: allow` to a line only when there is a real reason, and say why in a comment.

## Colour

Tokens are named by job. The neutrals are a warm graphite: low-chroma greys leaning slightly yellow, following Linear's 2026 move away from cool, blue-tinted greys. Light mode uses graphite ink instead of near-black, so text and the primary button don't land hard on the light surfaces. Contrast is against `surfaceCard`, or against the status fill for tags.

| Token | Light | Dark | Use for | Contrast (L / D) |
| --- | --- | --- | --- | --- |
| `textPrimary` | `#2E2D2B` | `#ECEAE6` | Body text, titles | 13.8 / 14.0 |
| `textSecondary` | `#64625E` | `#A6A39D` | Metadata, captions, idle sidebar items | 6.1 / 6.7 |
| `textTertiary` | `#85827C` | `#807D78` | Icons, chevrons, placeholders, timestamps. Never a sentence | 3.8 / 4.1 |
| `surfaceBase` | `#F6F5F3` | `#171615` | Window background | |
| `surfaceCard` | `#FFFFFF` | `#1E1D1C` | Cards, lists, sheets | |
| `surfaceRaised` | `#FFFFFF` | `#2B2A28` | Menus, dropdowns, pickers, hover on the window background | |
| `surfaceCardHover` | `#F4F2EF` | `#2A2927` | Hovered or selected row on a card | |
| `fillSecondary` | `#EFEDEA` | `#282725` | Secondary buttons, selected sidebar item, fields, tracks | |
| `fillSecondaryHover` | `#E8E6E2` | `#2F2E2C` | | |
| `fillSecondaryPressed` | `#DFDCD8` | `#373533` | | |
| `borderSubtle` | `#E6E3DF` | `#302F2D` | Card hairlines, dividers | |
| `borderStrong` | `#D5D2CD` | `#3D3B38` | Outlines of controls | |
| `actionPrimary` | `#353431` | `#ECEAE6` | The one main action; checkbox and focus accent | 12.5 / 15.0 with its label |
| `onActionPrimary` | `#FFFFFF` | `#171615` | Label on `actionPrimary` | |
| `actionDestructive` | `#D1312A` | `#D9372D` | Confirming a move to Trash, white label | 5.0 / 4.6 |
| `statusSafeText` / `Fill` | `#1F7A35` / `#E6F4EA` | `#5FD36B` / `#1B2E22` | Safe tag | 4.8 / 7.5 |
| `statusCheckText` / `Fill` | `#8A5300` / `#FAEEDA` | `#F2B84B` / `#332910` | Check first tag | 5.5 / 8.0 |
| `statusDangerText` / `Fill` | `#B4302A` / `#FBE8E5` | `#F47468` / `#321B19` | In use, errors | 5.2 / 5.8 |
| `statusUnsureText` / `Fill` | `#5A5853` / `#EFEDEA` | `#A9A6A0` / `#282725` | Unknown | 6.1 / 6.2 |

Hover and pressed shades exist for `actionPrimary` and `actionDestructive` too. `AppColors.Chart` holds the Overview breakdown colours (Okabe and Ito, colour-blind safe) and the warm greys for "everything else" and free space. It also holds the four Everything else page colours (#159), named for what the user can do: `managedInApps` blue, `yourFiles` amber, `leftAlone` coral and `managedByMacOS` grey. They differ in lightness as well as hue. Text on them is `bucketLabel`, except on the grey tile, which uses `managedByMacOSLabel`.

The cleanup celebration follows the app's appearance and draws on `surfaceBase`, so it uses the ordinary tokens in both modes. Plain white and black are only for shadows, masks, glyphs on coloured chart tiles, and the menu bar dropdown's native selection highlight.

## Buttons

`PurgeButtonStyle(role:size:width:)`, written `.buttonStyle(.purge(.primary))`.

| Role | Look | Use for |
| --- | --- | --- |
| `.primary` | `actionPrimary` fill | The one main action on a screen or sheet: Clean Selected, Uninstall, Get started |
| `.secondary` | `fillSecondary` fill, `borderStrong` outline | Every other action: Scan, Cancel, Not now |
| `.destructive` | `actionDestructive` fill, white label | Confirming a move to Trash in a sheet |
| `.quiet` | No fill until hover | Inline, low-weight actions: Turn Off, Open Settings, Retry |
| `.soft` | `fillSecondary` fill, no outline | A quiet action that needs a visible edge to line up with the text around it: the way back from Everything else |

| Size | Height | Label | Where |
| --- | --- | --- | --- |
| `.small` | 24pt | 12pt semibold | Rows, notices |
| `.regular` | 30pt | 13pt semibold | Toolbar, sheets, Settings |
| `.large` | 38pt | 15pt semibold | Onboarding, cleanup celebration |

`width:` is `.fit` (default), `.fill`, `.fixed(points)` for stacked actions that should line up, or `.square` for an icon-only button, which draws as a circle.

Rules:

- Icon-only buttons (`width: .square`) are for actions whose glyph needs no words, like removing a row from a list. The label is a `Label` with `.labelStyle(.iconOnly)` so VoiceOver still reads the title, and the button carries a `.help` tooltip.
- Every action is a pill. Controls that hold a value (pickers, fields, segmented controls) use a `md` rounded rectangle, so shape tells an action from a setting.
- One primary per view. A sheet ends with Cancel, then one primary or destructive action.
- Hover, pressed and disabled (0.45 opacity) come from the style. Don't add them per view.
- A spinner inside a button picks up the label colour; don't tint it.

## Type

Every `.font(...)` on text uses `AppStyle.Typography`, adding `.weight(...)` for emphasis. SF Symbols may still size their glyph with `.system(size:)`.

Text is set in [Onest](https://github.com/googlefonts/onest), bundled as `purge/Resources/Fonts/OnestText.ttf` under the SIL Open Font License (`Onest-OFL.txt`). The bundled copy has its digits removed, so a number inside ordinary text, such as "Last used 6 months ago", is drawn by the system font.

| Style | Spec | Tracking | Use for |
| --- | --- | --- | --- |
| `display` | SF Rounded 56 bold | 0 | Freed bytes on the celebration |
| `displaySmall` | SF Rounded 36 bold | 0 | Large totals |
| `title` | Onest 26 semibold | 0 | Onboarding and empty-state headings |
| `pageTitle` | Onest 20 semibold | 0 | Page headers |
| `sectionTitle` | Onest 15 semibold | +0.1 | Sheet titles, card headers, large buttons |
| `headline` | Onest 13 semibold | +0.15 | Group headers, regular buttons |
| `body` | Onest 13 regular | +0.15 | Paragraphs, labels |
| `rowTitle` | Onest 13 medium | +0.15 | List rows, menu rows |
| `callout` | Onest 12 regular | +0.25 | Helper text, small buttons |
| `metadata` / `metadataEmphasis` | Onest 11 regular / medium | +0.3 | Sizes, dates, paths |
| `micro` | Onest 10 semibold | +0.4 | Badges, count pills |
| `iconLabel` | Onest 8 semibold | +0.45 | File-type labels over a row icon |

Tracking is letter spacing in points, and each style carries its own. Onest has no optical sizes, so small text gets a little air and text from 20 pt up gets none. SF Rounded adjusts itself at every size and takes none. `.font(style)` sets the font and the tracking together; never add `.tracking` or `.kerning` to a view, the design lint fails on it.

Sizes, units and percentages are set in SF Rounded: add `.numbers` to the style, as in `.font(AppStyle.Typography.metadata.numbers)`, and keep `.monospacedDigit()` so figures don't shift as they change. When a line is mostly a figure, such as "285.9 GB used of 494.4 GB", the whole line takes `.numbers`. Paths and commands take `.monospaced()`, the system monospaced font at the style's size.

## Shape and spacing

| Radius | Value | Use for |
| --- | --- | --- |
| `xs` | 4 | Badges, progress and skeleton bars, small icon tiles |
| `sm` | 6 | Chips inside a field, dropdown rows, thumbnails |
| `md` | 8 | Pickers, fields, segmented controls |
| `lg` | 14 | Cards, list rows, sheets, notices |
| `xl` | 18 | Panels on the cleanup celebration |

Overview icons use `AppStyle.IconTile.shape()`: a continuous rounded rectangle
with a radius of 26% of the tile width, matching the bundled Apple Intelligence
mark. The default tile is 28pt. Use this shape for fills, rims, image clipping,
and the dashed Free outline so every tile shares the same corners. App artwork
is scaled to fill the tile before clipping its transparent outer padding.

Spacing: `xxSmall` 4, `xSmall` 8, `small` 12, `medium` 16, `large` 24, `xLarge` 32.

App Caches, Dev Tools and Large Files share `ScanListRowInsets.standard`: `xxSmall`
above and below each card and `medium` on either side, inside the native List's
outer inset. Cards and section headings align with the Select All row's 24pt page
inset. Lists start with real content so an invisible anchor row cannot add a top
gap. Dev Tools headings use `medium` above later sections, no extra space above
the first section, and `xxSmall` below, followed by the card's `xxSmall` top inset.

Cards use a 0.5pt `borderSubtle` hairline instead of a shadow.
