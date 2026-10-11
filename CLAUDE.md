# Purge

Purge is a macOS app in Swift and SwiftUI. It finds caches and junk and moves them to the Trash. Purge deletes files, so deletion safety comes before every other goal.

## Where things live

- `purge/` is the app. `purge/Services/` holds the scanners, the safety policy, and `FileDeleter`. `purge/Models/` and `purge/Views/` hold the rest.
- `purge/Resources/explanations.json` holds the explanation and safety level for each item.
- `purge/PrivilegedHelper/` and `PurgeHelper/` are the root helper the uninstaller uses.
- `PurgeTests/` holds the unit tests. They use Swift Testing (`@Test`, `#expect`), not XCTest. Shared test helpers are in `PurgeTests/Support/`.
- `docs/safety-notes.md` logs every time Purge removed, or could have removed, something it should not have.
- `docs/design-system.md` describes the colours, type, and spacing tokens.

## Commands

| Check | Command | Runs on Linux |
| --- | --- | --- |
| Unit tests | `xcodebuild -project purge.xcodeproj -scheme purge -destination 'platform=macOS' test` | No |
| Design tokens | `node scripts/lint-design-tokens.mjs` | Yes |
| Translations | `python3 scripts/check-localization.py` | Yes |

Cloud sessions run on Linux, so they can build no Swift code. Run the two Linux checks on every change. When you could not run the unit tests, say so in your reply and in the PR, and give the command.

## How a change gets made

- Open an issue first for anything bigger than a small fix.
- Make one fix or one feature per PR, on a branch off `main`. PRs are squash-merged.
- Write the PR title as a Conventional Commit with the issue number, for example `feat: warn when Large Files items sync to iCloud (#25)`. Types in use are feat, fix, docs, test, ci, refactor, and release.
- Write commit bodies and PR descriptions in plain, short sentences, and give real numbers when you measured something.
- For UI changes, add before and after screenshots, in light and dark mode, to `docs/screenshots/`.
- Match the style of the file you edit.

## App rules

- **Text.** Wrap every user-facing string in `String(localized:)`. Add the Simplified Chinese text to `purge/zh-Hans.lproj/`, then run the translations check.
- **Design.** Take colours, fonts, radii, and spacing from the tokens in `docs/design-system.md`. The design lint fails the build on a raw value.
- **Tests and real files.** The tests run inside a hosted copy of the app that shares the real user's defaults and files. Use `ThrowawayDefaults` and `FakeScans` from `PurgeTests/Support/`, never real user folders. Code that acts on launch must check `TestHost.isActive()` first.
- **Enums.** When you switch over `SafetyLevel`, `DeletionSafetyDecision`, or another enum of ours, list every case and leave out `default:`. A new case then fails the build in every place that must handle it.

## Deletion safety

- `SafetyLevel` in `purge/Models/SafetyInfo.swift` has three cases.
  - `.safe` is "Safe to Clean". Clean Safe Items and scheduled cleans take these items without asking.
  - `.medium` is "Check First".
  - `.unknown` is "Not Sure" and is never shown.
- Mark a path `.safe` only when it holds nothing but data its app rebuilds by itself. If it can hold settings, installed tools, keys, history, databases, projects, or offline downloads, it is `.medium` or not offered at all.
- Every removal goes through `DeletionSafetyPolicy.evaluate(_:)`. Never add a delete path that skips it.
- Files go to the Trash. Simulators, simulator runtimes, and Time Machine snapshots are removed for good, and the UI and docs must say so.
- Run the `deletion-safety-check` skill before you open a PR that touches any of these:
  - `purge/Services/DeletionSafetyPolicy.swift`, `SafetyTierList.swift`, `SafetyAllowlistSummary.swift`, `FileDeleter.swift`
  - any `purge/Services/*ScanPolicy.swift` or `*Scanner.swift`
  - `purge/Resources/explanations.json` or `purge/Models/ProjectArtifactCatalog.swift`
  - scheduled cleaning (`purge/Services/ScheduledCleaning*.swift`)
  - the root helper (`purge/PrivilegedHelper/`, `PurgeHelper/`)
- After a real incident, add an entry to `docs/safety-notes.md`. Its "What would have caught it earlier" section must name a test or check that exists in the repo, like `PurgeTests/AllowlistAuditTests.swift`. A safety lesson that is only written down is not done.
