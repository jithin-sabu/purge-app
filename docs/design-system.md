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

Hover and pressed shades exist for `actionPrimary` and `actionDestructive` too. `AppColors.Chart` holds the Overview breakdown colours (Okabe and Ito, colour-blind safe) and the warm greys for "everything else" and free space.

The cleanup celebration forces dark mode and draws on `surfaceBase`, so it uses the ordinary dark tokens. Plain white and black are only for shadows, masks, glyphs on coloured chart tiles, and the menu bar dropdown's native selection highlight.

## Buttons

`PurgeButtonStyle(role:size:width:)`, written `.buttonStyle(.purge(.primary))`.

| Role | Look | Use for |
| --- | --- | --- |
| `.primary` | `actionPrimary` fill | The one main action on a screen or sheet: Clean Selected, Uninstall, Get started |
| `.secondary` | `fillSecondary` fill, `borderStrong` outline | Every other action: Scan, Cancel, Not now |
| `.destructive` | `actionDestructive` fill, white label | Confirming a move to Trash in a sheet |
| `.quiet` | No fill until hover | Inline, low-weight actions: Turn Off, Open Settings, Retry |

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

| Style | Spec | Use for |
| --- | --- | --- |
| `display` | 56 bold, rounded | Freed bytes on the celebration |
| `displaySmall` | 36 bold, rounded | Large totals |
| `title` | 26 semibold, rounded | Onboarding and empty-state headings |
| `pageTitle` | 20 semibold, rounded | Page headers |
| `sectionTitle` | 15 semibold | Sheet titles, card headers, large buttons |
| `headline` | 13 semibold | Group headers, regular buttons |
| `body` | 13 regular | Paragraphs, labels |
| `rowTitle` | 13 medium | List rows, menu rows |
| `callout` | 12 regular | Helper text, small buttons |
| `metadata` / `metadataEmphasis` | 11 regular / medium | Sizes, dates, paths |
| `micro` | 10 semibold | Badges, count pills |

SF Rounded is for result numbers and titles only. Size numbers use `.monospacedDigit()`.

## Shape and spacing

| Radius | Value | Use for |
| --- | --- | --- |
| `xs` | 4 | Badges, progress and skeleton bars, small icon tiles |
| `sm` | 6 | Chips inside a field, dropdown rows, thumbnails |
| `md` | 8 | Pickers, fields, segmented controls |
| `lg` | 14 | Cards, list rows, sheets, notices |
| `xl` | 18 | Panels on the cleanup celebration |

Spacing: `xxSmall` 4, `xSmall` 8, `small` 12, `medium` 16, `large` 24, `xLarge` 32.

Cards use a 0.5pt `borderSubtle` hairline instead of a shadow.
