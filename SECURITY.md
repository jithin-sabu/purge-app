# Security Policy

Purge is an open-source macOS app that deletes files, so security and safety
are the whole point. This document explains how the app protects you, what it
runs as root, what it sends off your Mac, and how to report a problem.

## Reporting a vulnerability

If you find a security issue, a safety gap in the deletion logic, or a path
that could be deleted when it shouldn't be, please report it.

- Open a [private security advisory](https://github.com/jithin-sabu/purge-app/security/advisories/new), or
- Email the maintainer at the address listed on the GitHub profile.

Please do not open a public issue for a security or data-loss vulnerability
until it has been addressed. For non-security bugs, a normal issue is fine.

I aim to respond within a few days. This is a solo, free project, so please be
patient, but safety reports get priority over everything else.

## How Purge protects you

- **Trash by default.** Files and folders are moved to the macOS Trash, so
  you can put them back until you empty it yourself. Purge has no button that
  empties the Trash. Four removals are for good. iOS simulators
  and simulator runtimes go through Xcode's `simctl`. Time Machine local
  snapshots go through `tmutil deletelocalsnapshots`; Purge asks first and
  keeps the newest snapshot and the one from your last backup. The Apple
  Intelligence models on macOS 27 are released through Apple's own asset
  service and can be downloaded again; see below. Command-line tools and
  Homebrew cask apps you tick for removal through their package manager are
  uninstalled by that manager (`brew uninstall`, `npm uninstall -g`, and so
  on), which deletes them permanently; the review sheet says so, and a cask
  app has a Move All to Trash button to take the Trash route instead. Docker Desktop's data
  folder goes to the Trash. Purge does not run `docker system prune`.
- **Allowlist-based deletion.** Only paths that match an explicit safety
  allowlist are ever eligible for cleanup. Anything not on the list is never
  touched.
- **Never-delete protections.** Critical locations are blocked outright, and
  certain protected folders are only ever cleaned by their contents, never
  removed themselves.
- **You choose what goes.** Purge shows what is reclaimable and you select
  what to clear. The only thing that runs on its own is scheduled cleaning,
  which is off until you turn it on and only clears items marked Safe.
- **Open source.** The full deletion logic, including the allowlist, is in this
  repo for you to read or build from source yourself.

The full list of what Purge will never touch, every location it is allowed to
clean, and the Safe or Check First label on each item are on the
[safety page](https://purgemac.com/safety). The page is generated from the
app's source at build time, so it always matches the release it names.

When Purge has removed something it should not have, or could have, the
incident, the fix and what would have caught it earlier are written up in
[docs/safety-notes.md](docs/safety-notes.md). Entries are added only when
something real happens.

## What runs as root

Purge has one privileged helper, `io.getpurge.helper`. It is not set up when
you install the app. Purge asks you to enable it only when something you chose
to remove can't be moved without it: an app an administrator installed, or the
files a finished macOS update left in `/System/Volumes/Data/macOS Install Data`. macOS
then asks you to approve it under Login Items in System Settings. You can turn
it off at any time in Purge under Settings > Protected App Removal, or in Login
Items.

The helper does one thing: it moves an approved path into your Trash and hands
ownership of it back to you. It never deletes anything. The code is
in [`PurgeHelper/HelperService.swift`](PurgeHelper/HelperService.swift), and
it checks every request four ways:

- **Only the real Purge app can connect.** macOS checks each connection
  through `NSXPCConnection.setCodeSigningRequirement` and refuses any caller
  that is not the notarized Purge app signed by the same Apple developer team
  ([`PurgeHelper/HelperListenerDelegate.swift`](PurgeHelper/HelperListenerDelegate.swift)).
  The app runs the same check in reverse before it trusts the helper.
- **Only administrators.** A standard account is refused, even through a
  genuine copy of Purge.
- **Only known locations.** The helper checks every path itself instead of
  trusting the app. It accepts an app bundle in `/Applications` or
  `~/Applications` at any depth, never inside another bundle or package, or a
  direct child of a folder the uninstaller scans for leftovers, such as
  `~/Library/Application Support` or `/Library/LaunchDaemons`. The full list is in
  [`purge/PrivilegedHelper/PurgeHelperProtocol.swift`](purge/PrivilegedHelper/PurgeHelperProtocol.swift).
  It also accepts a direct child of `macOS Install Data`, never `Locked Files`,
  and only while that folder and everything in it are older than the moment the
  running macOS was installed, from `/Library/Receipts/InstallHistory.plist`.
  The helper reads those dates itself, so it never moves an update that is
  downloaded and waiting
  ([`purge/PrivilegedHelper/MacOSInstallLeftovers.swift`](purge/PrivilegedHelper/MacOSInstallLeftovers.swift)).
- **No symlink tricks.** Paths are opened one component at a time without
  following symlinks, and the move is a single atomic rename, so another
  process cannot swap a checked path for a different one mid-move. A path with
  a `.` or `..` part is refused, not resolved. Folders on the way are opened
  only to pass through, never to list, so the helper does not read your Trash
  ([`purge/PrivilegedHelper/HelperSupport.swift`](purge/PrivilegedHelper/HelperSupport.swift)).

The helper also runs only while it is needed. It quits after 30 idle seconds,
and macOS starts it again for the next request, so an update never leaves an
older copy running as root.

## Apple Intelligence models

On macOS 27, Purge can remove the Apple Intelligence models and download them
again (issue #133). This is the one place Purge uses private Apple interfaces
and the one change it makes that outlasts the app:

- **Two private calls**, both to Apple's asset subscription service: one asks
  it to release the model sets, the other asks for them back. They run in a
  separate helper, `io.getpurge.assetworker`, started once per call and gone
  after it, so a change in a future macOS crashes that helper and not Purge.
  Purge checks that macOS still names each set as expected before sending
  anything, and never sends a release with an empty list, which macOS would
  read as every asset on the Mac.
- **One configuration profile**, which you install yourself in System
  Settings. It only points the model downloads at a dead local address so
  macOS does not fetch them again. It stays in Device Management until you
  choose Download Again or remove it there; either brings the models back.
- **Nothing automatic.** Neither scheduled cleaning nor Clean Safe Items ever
  touches the models.

## Updates

Purge updates itself through [Sparkle](https://sparkle-project.org). Every
update is signed with an EdDSA key that exists only on the developer's machine.
The matching public key is built into the app (`SUPublicEDKey` in
[`purge/Info.plist`](purge/Info.plist)), and Purge refuses any download whose
signature does not match it. Someone who took over the download server still
could not push an update Purge would install.

## Network

Purge connects on its own only for updates: the daily update check and, if you
turn on Download and install updates automatically, the update download. Once a
day it fetches a small XML file (the appcast) from this repo to see whether a
newer version exists. It sends nothing about you, your files, or your Mac, and
there is no analytics or crash reporting. With automatic installs on, a new
version is downloaded from GitHub when the check finds one, and its signature is
checked before it is installed. You can turn the check off in Purge under
Settings > Updates > Check for updates automatically, which also stops the
downloads. Links in the app, such as the GitHub page, open in your browser only
when you click them.

## Verifying your download

Each release ships with a `.dmg.sha256` checksum file. Download it into the same
folder as the DMG, then in Terminal:

```
shasum -a 256 -c Purgev*.dmg.sha256
```

This confirms the file you downloaded matches the published release.

The release DMG is signed with a Developer ID Application certificate
(Jithin Sabu, team BX83ZBV95B), notarized by Apple, and stapled.
`scripts/make-dmg.sh` does that signing, notarization, and stapling. The
official Homebrew cask installs the same DMG (`brew install --cask purge`) and
checks its checksum. macOS opens that copy normally. The unsigned build in
GitHub Actions only compiles and runs tests. It is not a download. A copy you
build yourself is not notarized.

To check the signature of the installed release:

```
spctl --assess --verbose /Applications/Purge.app
```

The output should say `accepted` and `source=Notarized Developer ID`.

## Supported versions

Security and safety fixes are applied to the latest release. Please update to
the most recent version before reporting an issue.
