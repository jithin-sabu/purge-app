# Photos Library cleanup (#355)

## Scope

Add Photos to Review. Ask for read/write Photos permission only on opening it.
Show videos by original resource size, burst members with Photos' picks protected,
screenshots, screen recordings, and RAW+JPEG pairs. Start with no selection; clear
selection on refresh and category changes. Show local thumbnails for review.

RAW+JPEG pairs are review-only in this first implementation. PhotoKit represents
the originals as resources of one asset and exposes no supported resource-only
deletion operation. Deleting that asset would remove both originals. Similar-shot
matching is deferred, as requested in the issue.

## Architecture and safety

- A value model classifies assets and validates an immutable removal plan.
- A PhotoKit client reads metadata and thumbnails, and performs asset deletion.
  It never obtains filesystem library paths, uses private KVC, or downloads originals.
- On macOS 27 use public resource `dataSize`. Earlier macOS versions measure local
  original videos through PhotoKit's streaming data API, one at a time. Stop cancels
  the active request. Cloud-only or unreadable sizes remain unknown, sorted last.
  Streaming reads the whole video, so a measured size is kept for the app session
  by asset ID, modification date and resource list, and a refresh measures only
  new or changed videos. The first scan after launch still reads each local video once.
- A separate Photos store owns permission, scan, selection, confirmation and results.
  Initialization does no library work. Photos is not part of Scan Everything,
  automatic cleaning, filesystem deletion or filesystem cleanup history.
- Leaving the page stops a running scan or permission check. Coming back rechecks
  permission and keeps finished results and the selection unless access changed;
  the change block still validates every selected item. Declining Photos' own
  delete confirmation removes nothing and keeps the review and selection.
- A removal plan names only explicitly selected assets. Immediately before deletion,
  re-fetch selected assets and complete burst groups inside the PhotoKit change block.
  Refuse the whole plan if metadata or group membership changed, a resource pair is
  present, a selected asset became a pick, or Photos refuses deletion.
- Keep every user pick, automatic pick and burst representative. If Photos supplies
  none, keep the first member in stable identifier order. Never remove the last member.
- Confirm that deletion affects all devices using iCloud Photos and moves items to
  Recently Deleted, recoverable for 30 days unless removed permanently earlier.
  Report item counts, never claim these bytes are immediately freed on this Mac.

## Validation

Use Swift Testing with synthetic metadata and an injected client: permission timing,
empty selection, category changes, cancellation, unknown sizes, RAW pairs, all burst
pick variants, changed/deleted assets, changed group membership, permission revocation,
confirmation snapshots, concurrent operations and failed deletion. No test reads or
changes the user's Photos library. Run focused tests, relevant existing navigation
tests, design-token and localization checks, then capture dark-mode UI fixtures for
permission, review, burst, RAW-pair, confirmation, empty, error and completion states.

## References

- [Issue #355](https://github.com/jithin-sabu/purge-app/issues/355)
- [PHAssetResource](https://developer.apple.com/documentation/photos/phassetresource)
- [alternatePhoto](https://developer.apple.com/documentation/photos/phassetresourcetype/alternatephoto)
- [PHAssetChangeRequest](https://developer.apple.com/documentation/photos/phassetchangerequest)
- [All burst assets](https://developer.apple.com/documentation/photos/phfetchoptions/includeallburstassets)
- [Streaming resource data](https://developer.apple.com/documentation/photos/phassetresourcemanager)

## Implementation and review

Implemented on `feat/photos-library-355`, based on upstream `8d64ee6`. The fast
size-metadata path is compiled with Swift 6.4 or newer; older SDKs use the same
local-only streaming fallback as older systems. No API returns a guessed zero
for an unknown size.

The focused Photos, navigation and Overview tests passed on this Mac after review:
54 tests, 66 runs including parameterized cases. An unsigned Release build passed,
as did design-token, translation and plist checks. The translation check reports
two existing Turkish explanation warnings for prek; this feature adds no missing
translations.

The broader unit suite, split from the two stress suites as in CI, passed 2,107 of
2,108 tests. Its only failure was
`AppleIntelligenceAliasLanguageTests.thisMacDefinesEveryLanguageAliasInTheCatalog`:
this Mac's OS supplies `isIFPEnabled_…_language_…` aliases where the test expects
`language_…`. The same failure reproduced on unchanged upstream `8d64ee6` (four
other tests in that baseline suite passed). The isolated ProcessRunner suite
passed all nine tests, and FolderSizingConcurrency passed all seven tests.

These are fixture tests, not a live-library deletion test. Real authorization UI,
PhotoKit deletion/Recently Deleted behavior, and the macOS 13 streaming fallback
still need a manual smoke test with a disposable Photos library. No test or
screenshot reads or changes the user's library. Release signing with the
maintainer's Developer ID certificate is unavailable here; local tests use ad hoc
signing.

### Dark-mode screenshots

The before image is the upstream Overview at `8d64ee6`, where Review had no Photos
tab. All after images render the production views with synthetic metadata and
placeholder thumbnails. Completion is a fake successful operation, not an actual
library change. The temporary capture harness is not part of the app or tests.

| State | Screenshot |
| --- | --- |
| Before, upstream main | [Before](screenshots/355-before-dark.png) |
| Before Photos access | [Permission](screenshots/355-permission-dark.png) |
| Denied / restricted access | [Denied](screenshots/355-denied-dark.png), [restricted](screenshots/355-restricted-dark.png) |
| Limited access | [Limited](screenshots/355-limited-dark.png) |
| Videos and unknown size | [Videos](screenshots/355-videos-dark.png) |
| Bursts with protected picks | [Bursts](screenshots/355-bursts-dark.png) |
| RAW+JPEG review only | [Pairs](screenshots/355-raw-pairs-dark.png) |
| Other paired originals protected | [RAW+HEIF](screenshots/355-paired-originals-dark.png) |
| Review preserved after declining confirmation | [Cancelled](screenshots/355-cancelled-dark.png) |
| Screenshots / recordings | [Screenshots](screenshots/355-screenshots-dark.png), [recordings](screenshots/355-recordings-dark.png) |
| Scanning / stopped | [Scanning](screenshots/355-scanning-dark.png), [stopped](screenshots/355-stopped-dark.png) |
| Empty / failed reading | [Empty](screenshots/355-empty-dark.png), [error](screenshots/355-error-dark.png) |
| Confirmation / operation pending | [Confirmation](screenshots/355-confirmation-dark.png), [pending](screenshots/355-removing-dark.png) |
| Completion | [Completion](screenshots/355-completion-dark.png) |

### Blast radius

- Newly removable: explicitly selected whole PhotoKit assets, such as a large
  video, a screenshot, or an unpicked burst member. They are personal media for
  individual review, never Safe to Clean. There are no filesystem example paths:
  the boundary accepts PhotoKit local identifiers only.
- Gate: `PhotosRemovalPlan.validate`, called again in `PhotoKitLibrary.remove`,
  refuses changed metadata, changed burst membership, protected picks, any asset
  with two original photos (RAW+JPEG, RAW+HEIF or any other second original),
  hidden items and non-deletable assets. `PhotosLibraryPolicyTests` pins
  these rules; `PhotosLibraryStoreTests` covers selection and confirmation.
- Reversibility: PhotoKit deletion, recoverable in Recently Deleted subject to
  Photos' retention policy. The app warns about iCloud sync before confirmation.
- Checked: filesystem deletion, Clean Safe Items, scheduled cleaning, Scan
  Everything and filesystem cleanup history do not consume Photos candidates.
- Remaining risk (`purge/Services/PhotoKitLibrary.swift:118`): the live PhotoKit
  boundary is compile-checked and uses supported APIs, but actual system permission
  prompts and deletion were not exercised with real media. RAW+JPEG resource-only
  cleanup remains intentionally unsupported.
