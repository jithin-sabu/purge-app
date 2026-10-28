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
- Write the PR title as a Conventional Commit with the issue number, for example `feat: warn when Large Files items sync to iCloud (#25)`. Types in use are feat, fix, perf, docs, test, ci, refactor, and release.
- Write commit bodies and PR descriptions in plain, short sentences, and give real numbers when you measured something.
- For UI changes, add before and after screenshots in dark mode to `docs/screenshots/`. Light mode is not needed. Cover every scenario the change can produce and every screen it touches, including Cleanup History and any other place whose text changed.
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
  - `.unknown` is "Not Sure". It never appears in scan results, but the delete confirmation sheets can still list it.
- Mark a path `.safe` only when it holds nothing but data its app rebuilds by itself. If it can hold settings, installed tools, keys, history, databases, projects, or offline downloads, it is `.medium` or not offered at all.
- Every cache and Dev Tools removal goes through `DeletionSafetyPolicy.evaluate(_:)`. Never add a delete path that skips it.
  - Items the user picks one by one have their own gate instead, because they are the user's own files and `evaluate` refuses those by design. Large Files, AI models, the uninstaller, and command-line tools go through `FileDeleter.deleteUserSelectedFiles`, which checks `LargeFileScanPolicy`, `AIModelScanPolicy`, `AppUninstallScanPolicy`, and `CommandLineToolScanPolicy`. Those gates are deletion-safety code too. They never feed Clean Safe Items or scheduled cleans.
  - `CommandLineToolScanPolicy` (#225) re-reads the pairs from disk at delete time. It accepts only a standalone tool's folder, the shims in `~/.local/bin` that point into it, and its LaunchAgent plists. A shim pairs only on positive evidence: it is named after the folder, the program it runs is an executable on disk inside the folder, and every path it names sits in that folder. Values given to a variable or an option never count. It never accepts a shared folder (`~/.gemini`, `~/.config`, `~/.local/share`), a version manager's (`~/.nvm`), an app catalog folder, a git checkout, or a folder holding an AI model store, compared without case. A LaunchAgent pairs only when the program it starts is in the folder. Before the move, Purge stops the paired LaunchAgents and refuses while `lsof` shows a process using the folder; on a refusal it starts the stopped jobs again.
  - Another exception is the Apple Intelligence models (#133). Purge deletes no files there: Apple's asset service releases each set, one name per request, from the fixed list in `purge/Models/AppleIntelligenceModels.swift`. A release with an empty list means every asset on the Mac, so `PurgeAssetWorker/` refuses one and the app never builds one. Don't use this exception as a pattern for anything else.
  - Simulator runtimes (#104) are the third exception. Purge deletes no files there either. `simctl runtime delete` removes each image by the identifier `simctl runtime list` gave it, and the path on the row is only a handle. The gates are these. The scan keeps only images `simctl` marks `deletable` (`SimulatorRuntime.parseRuntimeList`). It leaves out an older-format runtime (not "Patchable") when Apple keeps a download of its build under `/System/Library/AssetsV2`, and every older-format one when that folder can't be read (#165). Such a runtime is mounted from inside the download, which `simctl` can't remove, so deleting it frees next to nothing and it comes back at the next restart. Purge only reads AssetsV2. `FileDeleter.removeSimulatorRuntime` reads the same rule again from disk right before `runtime delete` and skips the runtime for safety when it fails. The clean records the space the volume gave back for each runtime, not `simctl`'s size, and claims nothing when that can't be read and the download may still be there. Runtimes are always Check First (#136), and the user must pick the row and confirm. Clean Safe Items and scheduled cleans never pass runtime identifiers to `FileDeleter`, even for a row marked Safe. A runtime path that reaches `FileDeleter` without its identifier goes to `evaluate`, which refuses it. `PurgeTests/SimulatorRuntimeTests.swift`, `SimulatorRuntimeStoreTests.swift`, and `FileDeleterSimulatorRuntimeTests.swift` check each gate. Simulator devices are not part of this exception: they go through `evaluate` before `simctl delete`.
  - Package-manager tools (#225) are the fourth exception. Purge deletes no files there either. It runs the manager's own uninstall (`brew uninstall --formula`, `npm uninstall -g`, `pipx uninstall`, `uv tool uninstall`, `cargo uninstall`) for each tool the user ticked and confirmed, one at a time, with an absolute program path, argv and no shell, through `PackageManagerUninstaller`. It never adds a flag that skips the manager's dependency checks. Names come from folders on disk, so `PackageManager.isValidPackageName` checks them first. Nothing a manager owns is ever a `FileDeleter` candidate.
  - Homebrew cask apps (#254) are the fifth exception, and use the fourth's runner. `HomebrewCaskCatalog` reads the Caskroom link `Caskroom/<token>/<version>/<App>.app -> /Applications/<App>.app` and nothing else; an app is a cask's only when that link points at its bundle and the cask links no other app, re-read at delete time. A cask that installs several apps is never offered, because `brew uninstall --cask` removes them all. Homebrew's uninstall also runs the cask's own `uninstall` stanza (quit, launchctl, pkgutil, delete, scripts), all of it permanent, and the sheet says so. The review sheet offers two buttons when a cask app's bundle is ticked, Remove with Homebrew and Move All to Trash, and its intro says Homebrew deletes the app permanently. Purge runs `brew uninstall --cask <token>` through `PackageManagerUninstaller`, never `--force` or `--zap`, then `brew cleanup --scrub <token>` to drop the cask's cached download (a plain `brew cleanup` keeps it), and its own leftover review still moves the rest to the Trash. If Homebrew refuses, the app takes the ordinary Trash route and the completion screen shows Homebrew's message. Clean Safe Items and scheduled cleans never reach this.
  - Keep Only in iCloud (#106), Finder's Remove Download, is the sixth exception. Purge deletes no files there either. `FileManager.evictUbiquitousItem(at:)` drops the copy on this Mac, and the file stays in iCloud and at its path, so opening it downloads it again. `ICloudDownloadPolicy` is the gate, and `ICloudDownloadRemover` runs it again from disk right before each eviction. The file must sit under a folder Large Files walks, be a regular file with one name (not a link, not hard-linked), be in iCloud, be uploaded, have no sync conflict, be downloaded and current, carry the APFS purgeable flag (`EF_IS_PURGEABLE`, which a Keep Downloaded file lacks), be unchanged for five minutes, and not be open in any process (`OpenFileCheck`; when `lsof` can't be read nothing is evicted). Only `PurgeStore.confirmRemoveDownloads` calls the remover, after the user picks the rows and confirms. Clean Safe Items and scheduled cleans never do. Files in iCloud Drive's own folder (`~/Library/Mobile Documents/com~apple~CloudDocs`) are offered for Keep Only in iCloud only, never for the Trash, because trashing them removes them from every device. `PurgeTests/ICloudDownloadTests.swift` checks each gate.
- Files go to the Trash. Simulators, simulator runtimes, Time Machine snapshots, the Apple Intelligence models, and tools a package manager removes are removed for good, and the UI and docs must say so. Anything removed for good is never `.safe`, because Clean Safe Items and scheduled cleans only move things to the Trash (#136).
- Run the `deletion-safety-check` skill before you open a PR that touches any of these:
  - `purge/Services/DeletionSafetyPolicy.swift`, `SafetyTierList.swift`, `SafetyAllowlistSummary.swift`, `FileDeleter.swift`
  - any `purge/Services/*ScanPolicy.swift` or `*Scanner.swift`
  - `purge/Resources/explanations.json` or `purge/Models/ProjectArtifactCatalog.swift`
  - simulator runtimes (`purge/Models/SimulatorRuntime.swift`), whose `deletable` filter is a deletion gate
  - scheduled cleaning (`purge/Services/ScheduledCleaning*.swift`)
  - the root helper (`purge/PrivilegedHelper/`, `PurgeHelper/`)
  - the Apple Intelligence models (`purge/Services/AppleIntelligenceModel*.swift`, `purge/Models/AppleIntelligenceModels.swift`, `PurgeAssetWorker/`)
  - Keep Only in iCloud (`purge/Services/ICloudDownload*.swift`)
  - command-line tools (`purge/Services/CommandLineTool*.swift`, `PackageManager*.swift`, `OpenFileCheck.swift`, `LaunchAgentStopper.swift`, `purge/Resources/command-line-tools.json`)
  - Homebrew cask apps (`purge/Services/HomebrewCaskCatalog.swift`)
- After a real incident, add an entry to `docs/safety-notes.md`. Its "What would have caught it earlier" section must name a test or check that exists in the repo, like `PurgeTests/AllowlistAuditTests.swift`. A safety lesson that is only written down is not done.
