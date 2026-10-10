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
  anything removed can be restored until you empty it yourself. Purge has no
  button that empties the Trash. Two kinds of item are not ordinary files and
  cannot go to the Trash: iOS simulators and simulator runtimes, which Purge
  removes through Xcode's `simctl`, and Time Machine local snapshots, which it
  removes through `tmutil`. Purge warns you before removing snapshots and never
  removes the newest one.
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
you install the app. Purge asks you to enable it only when an uninstall hits an
app you cannot move yourself, usually one an administrator installed. macOS
then asks you to approve it under Login Items in System Settings. You can turn
it off at any time in Purge under Settings > Protected App Removal, or in Login
Items.

The helper does one thing: it moves an approved uninstall path into your Trash
and hands ownership of it back to you. It never deletes anything. The code is
in [`PurgeHelper/HelperService.swift`](PurgeHelper/HelperService.swift), and
it checks every request four ways:

- **Only the real Purge app can connect.** macOS checks each connection
  through `NSXPCConnection.setCodeSigningRequirement` and refuses any caller
  that is not the notarized Purge app signed by the same Apple developer team
  ([`PurgeHelper/HelperListenerDelegate.swift`](PurgeHelper/HelperListenerDelegate.swift)).
  The app runs the same check in reverse before it trusts the helper.
- **Only administrators.** A standard account is refused, even through a
  genuine copy of Purge.
- **Only uninstall locations.** The helper checks every path itself instead of
  trusting the app. It accepts an app bundle in `/Applications` or
  `~/Applications`, or a direct child of a folder the uninstaller scans for
  leftovers, such as `~/Library/Application Support` or
  `/Library/LaunchDaemons`. The full list is in
  [`purge/PrivilegedHelper/PurgeHelperProtocol.swift`](purge/PrivilegedHelper/PurgeHelperProtocol.swift).
- **No symlink tricks.** Paths are opened one component at a time without
  following symlinks, and the move is a single atomic rename, so another
  process cannot swap a checked path for a different one mid-move.

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

Purge is signed with a Developer ID certificate and notarized by Apple, so it
opens normally with no extra steps. To check the signature yourself after
installing:

```
spctl --assess --verbose /Applications/Purge.app
```

The output should say `accepted` and `source=Notarized Developer ID`.

## Supported versions

Security and safety fixes are applied to the latest release. Please update to
the most recent version before reporting an issue.
