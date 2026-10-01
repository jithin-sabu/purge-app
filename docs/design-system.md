# Purge design system

Every colour, button, font and radius in Purge comes from three files:

- `purge/Theme/AppColors.swift`: colours
- `purge/Views/AppStyle.swift`: type scale, radii, spacing, row metrics
- `purge/Views/PurgeButtonStyle.swift`: the one button style

`node scripts/lint-design-tokens.mjs` (also `npm run lint:design`, and a CI step) fails when a view uses a raw colour, a SwiftUI grey like `.secondary`, a point size or text style on text, a literal corner radius, or a removed button style. Add `design-lint: allow` to a line only when there is a real reason, and say why in a comment.

## Colour

Tokens are named by job. Light mode uses a charcoal ink instead of near-black, so text and the primary button don't land hard on the light surfaces. Contrast is against `surfaceCard`, or against the status fill for tags.

| Token | Light | Dark | Use for | Contrast (L / D) |
| --- | --- | --- | --- | --- |
| `textPrimary` | `#2C2E35` | `#E9EAED` | Body text, titles | 13.6 / 14.0 |
| `textSecondary` | `#61636C` | `#A1A3AC` | Metadata, captions, idle sidebar items | 6.0 / 6.7 |
| `textTertiary` | `#80828C` | `#7D7F89` | Icons, chevrons, placeholders, timestamps. Never a sentence | 3.8 / 4.2 |
| `surfaceBase` | `#F6F6F8` | `#15161A` | Window background | |
| `surfaceCard` | `#FFFFFF` | `#1C1D22` | Cards, lists, sheets | |
| `surfaceRaised` | `#FFFFFF` | `#2A2B33` | Menus, dropdowns, pickers, hover on the window background | |
| `surfaceCardHover` | `#F2F3F5` | `#2A2B33` | Hovered or selected row on a card | |
| `fillSecondary` | `#EEEFF2` | `#26272E` | Secondary buttons, selected sidebar item, fields, tracks | |
| `fillSecondaryHover` | `#E7E8EC` | `#2D2E36` | | |
| `fillSecondaryPressed` | `#DFE0E5` | `#34353E` | | |
| `borderSubtle` | `#E4E5E9` | `#2E2F37` | Card hairlines, dividers | |
| `borderStrong` | `#D3D5DA` | `#3A3B44` | Outlines of controls | |
| `actionPrimary` | `#34363E` | `#E9EAED` | The one main action; checkbox and focus accent | 12.1 / 15.0 with its label |
| `onActionPrimary` | `#FFFFFF` | `#15161A` | Label on `actionPrimary` | |
| `actionDestructive` | `#D1312A` | `#D9372D` | Confirming a move to Trash, white label | 5.0 / 4.6 |
| `statusSafeText` / `Fill` | `#1F7A35` / `#E6F4EA` | `#5FD36B` / `#1B2E22` | Safe tag | 4.8 / 7.5 |
| `statusCheckText` / `Fill` | `#8A5300` / `#FAEEDA` | `#F2B84B` / `#332910` | Check first tag | 5.5 / 8.0 |
| `statusDangerText` / `Fill` | `#B4302A` / `#FBE8E5` | `#F47468` / `#321B19` | In use, errors | 5.2 / 5.8 |
| `statusUnsureText` / `Fill` | `#565861` / `#EEEEF1` | `#A7A9B2` / `#26272D` | Unknown | 6.1 / 6.0 |

Hover and pressed shades exist for `actionPrimary` and `actionDestructive` too. `AppColors.Chart` holds the Overview breakdown colours (Okabe and Ito, colour-blind safe) and the free-space grey.

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

`width:` is `.fit` (default), `.fill`, or `.fixed(points)` for stacked actions that should line up.

Rules:

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
