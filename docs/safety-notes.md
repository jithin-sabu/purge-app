# Safety notes

Purge deletes files, so the times it got that wrong are worth writing down.
This is the log. It has one entry for each time Purge removed, or could have
removed, something it should not have. Entries marked "found internally" were
fixed before anyone reported them. Each entry says what happened, who was
affected, what changed in the code, and what would have caught it earlier.

Entries are added only when something real happens. If you have hit something
that belongs here, [SECURITY.md](../SECURITY.md) says how to report it.

Newest first.

## 2026-10-15: Projects in use were Safe to Clean under "Consider stale after"

**Found internally**, no report. **Fixed:** not yet shipped. **Affected:** v1.1.1 to v1.10.0, for anyone who never changed the setting.

### What happened

Settings showed "Consider stale after: 6 months", but that value was only a
display default and was never saved. The scanner read the missing setting as
0, and 0 means Show all. So the activity check from the 2026-10-01 entry below
never ran. A project edited an hour ago was listed, its `node_modules` and
build folders were Safe to Clean, and Clean Safe Items or a scheduled clean
could move them to the Trash. The orphan leftover scan read the same setting
and used its 30-day floor instead of 6 months.

The activity check also failed open in two ways. It reads at most 20,000
entries in a project, and a walk that stopped there answered "not used". And it
skipped every folder named like a build folder of any language, such as
`build`, `bin` or `vendor`, so edits to the user's own scripts in a Node
project's `build/` folder did not count as use.

Show all, chosen on purpose, had the same effect as the bug: a project edited
an hour ago was listed with its folders Safe to Clean.

### Who was affected

Nobody reported a loss. Anyone with code projects who had never changed the
setting was exposed. The folders went to the Trash, so they could be put back
or rebuilt with the project's install command.

### What changed

A missing setting now reads as the 6 months Settings shows. Only a saved Show
all means Show all. A walk that hits the entry limit now counts as activity,
so a project too big to check is left off the list. The walk skips only the
folders being offered for that project, plus `.git` and `node_modules`.

Show all still lists every project, but folders of a project worked on in the
last 6 months are Check First, so Clean Safe Items and scheduled cleans skip
them. The project keeps that fact, so Reset to automatic and Recategorize land
on Check First again. A path the user marked Safe by hand stays Safe.

### What would have caught it earlier

`StalenessThresholdDefaultTests` in
[`PurgeTests/ProjectActivityPolicyTests.swift`](../PurgeTests/ProjectActivityPolicyTests.swift)
reads the setting from a fresh `ThrowawayDefaults` and expects 180 days, and
checks that a project edited today is not listed. In the same file,
`entryLimitCountsAsActive` covers the cut-off walk, `sameNameFolderIsWalked`
the skipped folder names, `showAllRecentProjectIsCheckFirst` Show all, and
`RecentProjectResetTests` the reset and recategorize paths. The earlier tests
always passed the age in directly, so none of them read the setting the way the
scanner does.

## 2026-10-14: Simulators were Safe to Clean although they are removed for good

**Reported** by @zihua-zhang while testing the 1.9.0 Chinese beta ([#110](https://github.com/jithin-sabu/purge-app/issues/110)). **Fixed:** [#166](https://github.com/jithin-sabu/purge-app/pull/166) and [#167](https://github.com/jithin-sabu/purge-app/pull/167), not yet shipped. **Affected:** v1.1.0 to v1.10.0.

### What happened

Dev Tools badged a simulator device Safe when `simctl` gave no last-booted
date. `simctl` leaves that date out for some devices that have been used, so
a device someone still used could show as Safe. Deleting a device removes its
apps and data with `simctl delete`, and nothing goes to the Trash. Select All
in Dev Tools ticks Safe rows first, so one click could select such a device.
The report came from a mismatch: the row said Safe, but the Overview counted
nothing safe under Dev Tools.

Review of the fix found a second case. Devices Xcode can't run were Safe
whatever their last use. Removing a simulator runtime, which Purge can do,
makes its devices unavailable while their apps and data stay on disk and come
back when the runtime is downloaded again. On the next scan those devices
showed as Safe.

Both cases come from one mistake. Safe means Clean Safe Items and scheduled
cleans take the item without asking, and those only move things to the Trash.
Simulators and runtimes never went to either, so a Safe badge on them promised
something the rest of the app did not do.

### Who was affected

Nobody reported a loss. Clean Safe Items, scheduled cleans, the menu bar and
the Shortcuts action never included simulators, because they only move things
to the Trash. A device could only be removed by ticking it in Dev Tools,
directly or through Select All, and confirming the delete.

### What changed

Simulator devices and runtimes are always Check First. Their explanations
still say when each was last used and whether any simulator uses a runtime, so
a forgotten one is still easy to spot. Dev Tools and the Overview now agree.
CLAUDE.md now says that anything removed for good is never Safe.

### What would have caught it earlier

A rule that Safe only goes on things the one-click clean takes, checked by a
test. `noSimulatorRowIsEverSafe` in `PurgeTests/SimulatorDeviceSafetyTests.swift`
runs every branch of both simulator safety functions, and the one-click tests
there and in `SimulatorRuntimeStoreTests.swift` force a simulator Safe to prove
the clean skips it anyway.

## 2026-10-06: Allowlist audit moved data folders out of Safe to Clean

**Found internally**, no report. **Fixed:** [#103](https://github.com/jithin-sabu/purge-app/pull/103), shipped in v1.8.1 (2026-10-06). **Affected:** v1.1.0 to v1.8.0.

### What happened

An audit of everything Safe to Clean holds, checked against
[Mole](https://github.com/tw93/Mole)'s cleanup rules and against what people
find in System Data. Safe rows are what Clean Safe Items and scheduled cleans
take without asking, so the question was whether anything in Safe held more
than a cache. Several entries did:

- `~/.gem` held installed gems and their commands.
- `~/.sbt` held the user's own sbt settings.
- `~/.pub-cache` held globally installed Dart tools.
- VS Code and Cursor `workspaceStorage` held per-project AI chat history.
- Zed's `db` was its workspace database.
- The JetBrains caches included Local History.
- `~/.android` was offered whole, including emulators, the adb key and
  `debug.keystore`.
- The Spotify cache was offered even when offline downloads were present.

### Who was affected

Nobody reported a loss. Anyone who ran Clean Safe Items or a scheduled clean
with one of these folders present would have had it moved to the Trash.

### What changed

Each entry was narrowed to its cache part, moved to Check First, or dropped.
Maven, the global Gradle cache, NuGet, Cabal, the Ivy cache, CocoaPods spec
repos and Playwright browsers moved to Check First. Finder, Dock, Control
Center and System Settings caches, endpoint security agents and input methods
are now never offered. The full diff is in
[`explanations.json`](https://github.com/jithin-sabu/purge-app/blob/v1.8.1/purge/Resources/explanations.json)
and
[`DeletionSafetyPolicy.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.8.1/purge/Services/DeletionSafetyPolicy.swift)
at v1.8.1.

### What would have caught it earlier

The audit itself, run before each entry shipped instead of after. The
[safety page](https://purgemac.com/safety) is now generated from the source
at build time, so the published list cannot drift from the code.

## 2026-10-01: An active project's build folders could look stale and be swept

**Found internally**, no report. **Fixed:** [#87](https://github.com/jithin-sabu/purge-app/pull/87), shipped in v1.7.1 (2026-10-05). **Affected:** v1.1.1 to v1.7.0.

### What happened

Dev Projects has a "Consider stale after" setting. It compared that age
against the date on the artifact folder itself. A folder's date only changes
when something is added to or removed from its top level, so `node_modules`
said when `npm install` last ran, not when anyone last opened the project. A
project worked on every day with stable dependencies looked stale, its folders
were Safe to Clean, and Clean Safe Items or a scheduled clean could move them
to the Trash.

### Who was affected

Nobody reported a loss. Anyone with an active project whose dependencies had
not changed for longer than the stale setting was exposed.

### What changed

Age now comes from the project, not the folder
([`ProjectActivityPolicy.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.7.1/purge/Services/ProjectActivityPolicy.swift)).
A project is active if its git metadata, any file inside it, or the artifact
folders' own dates are newer than the cutoff. A project in use right now, with
a process working inside it or a git lock present, is hidden whatever the age
setting says. Four tests describing the bug fail on the old rule.

### What would have caught it earlier

"Is anyone using this" is process state, not a folder date. The same lesson as
the Chrome entry below, applied to projects.

## 2026-10-01: Docker Desktop was Safe to Clean, so one-click cleans could trash the VM disk

**Found internally**, no report. **Fixed:** [#86](https://github.com/jithin-sabu/purge-app/pull/86), shipped in v1.7.1 (2026-10-05). **Affected:** v1.1.0 to v1.7.0.

### What happened

The Docker Desktop row in Dev Tools is the whole
`~/Library/Containers/com.docker.docker` folder. Almost all of it is
`Docker.raw`, Docker's VM disk, which holds every image, container and volume.
Volumes can hold the only copy of a database. The `docker` entry in
`explanations.json` was tagged `safe`, so Clean Safe Items and scheduled
cleaning both picked it up. A comment in `DeletionSafetyPolicy` said "Check
First, not Safe", but that list only decides whether a path can be offered at
all, so the comment never took effect.

Found while scoping [#67](https://github.com/jithin-sabu/purge-app/issues/67),
which assumed Docker was already Check First.

### Who was affected

Nobody reported a loss. Anyone with Docker Desktop installed who ran Clean
Safe Items or a scheduled clean would have had the VM disk moved to the Trash.
It can be put back from there, but a running Docker would have lost it.

### What changed

The row is Check First. Its description says what the folder holds, to quit
Docker Desktop first, and points at `docker system prune` for freeing space
without losing volumes.
[`DockerSafetyTierTests.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.7.1/PurgeTests/DockerSafetyTierTests.swift)
checks both the bundled record and the resolved row. Both tests fail on the
old tag.

### What would have caught it earlier

A test that asserts the tier of the resolved row for every entry that can hold
user data. And a rule that a comment never sets a tier: the tag in
`explanations.json` is the only thing that does.

## 2026-09-21: Old Version cleanup removed the framework Chrome was running from

**Reported:** [#75](https://github.com/jithin-sabu/purge-app/issues/75), Purge 1.5.2. **Fixed:** [#76](https://github.com/jithin-sabu/purge-app/pull/76), shipped in v1.5.3 (2026-09-24). **Affected:** v1.1.2 to v1.5.2.

### What happened

Chrome had been running since 8 September and was never relaunched. In the
meantime its updater had installed two newer versions in the background, so
the bundle held three framework folders:

- `Versions/152.0.7977.76`, loaded by the running process
- `Versions/153.0.8010.48`
- `Versions/153.0.8010.50`, the `Current` symlink target

Purge listed the first two as "Google Chrome Old Version" under Check First.
Cleaning them moved both to the Trash. Straight away Chrome could not load any
page in any tab, while the network itself was fine. All 25 Chrome helper
processes were still running from the deleted 152 folder, and Chrome could not
spawn new renderer or network processes from a path that no longer existed.

Quitting and relaunching Chrome fixed it, since `Current` pointed to a
complete 153.0.8010.50. No data was lost, but the browser was dead until the
user worked out why.

### Who was affected

One user reported it. Anyone running a Chromium browser across a background
update, without relaunching, who then cleaned the Old Version rows. The
scanner had worked this way since it shipped in v1.1.2: it offered every
`Versions/<x>` folder that was not the `Current` target, and never asked
whether a process was running from it. Its explanation said "Usually safe to
remove, but reinstall the browser if it fails to launch."

### What changed

Purge now reads running process paths before offering a version, and checks
again before deleting.

- [`DeletionSafetyPolicy.staleBrowserFrameworkRefusesDeletion`](https://github.com/jithin-sabu/purge-app/blob/v1.5.3/purge/Services/DeletionSafetyPolicy.swift)
  reads the bundle and executable path of every running application, maps
  each Chrome helper back to its outer `.app`, and pulls the version out of
  `Versions/<version>/` in the path.
- `shouldOfferStaleFrameworkVersion` applies three rules. Never offer the
  `Current` target. Never offer a version a process is executing from. If the
  browser is running but no process path reveals a version, offer nothing.
- That refusal stays out of the offered-for-cleanup cache, because the answer
  flips when the user quits the browser.
- [`FileDeleter`](https://github.com/jithin-sabu/purge-app/blob/v1.5.3/purge/Services/FileDeleter.swift)
  re-runs the check after sizing, immediately before the item goes to the
  Trash, and re-reads the `Current` symlink at that moment. An item that no
  longer passes is reported as "skipped for safety" instead of deleted. This
  delete-time re-check is the part that protects against the next case,
  whatever it turns out to be.
- The row's explanation now says to quit and relaunch the browser first, and
  that the browser deletes leftover versions itself on relaunch.
- [`StaleBrowserFrameworkPolicyTests.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.5.3/PurgeTests/StaleBrowserFrameworkPolicyTests.swift)
  pins the decision table.

### What would have caught it earlier

An item whose safety depends on something outside the filesystem, here a
running app, needs that state checked at scan time and again at delete time.
A test that modelled a running browser on an old version would have failed on
the v1.1.2 code.

## 2026-09-11: JetBrains cleaner deleted installed plugins and all IDE settings

**Reported** by a user outside GitHub, no tracked issue. **Fixed:** [#48](https://github.com/jithin-sabu/purge-app/pull/48), shipped in v1.5.0 (2026-09-11). **Affected:** v1.1.0 to v1.4.0.

### What happened

The "JetBrains Cache" row targeted two folders. `~/Library/Caches/JetBrains`
is a real cache: indexes and compiler output, rebuilt on next launch.
`~/Library/Application Support/JetBrains` is not. Since the 2020.1 layout it
holds installed plugins (`plugins/`) and every IDE setting (`options/`,
`keymaps/`, `codestyles/` and more). Both paths were delete targets in
`DevScanner` and both were on the allowlist, under the label "Safe to delete
and will be recreated when you open the IDE again." Cleaning the row wiped
every plugin and every setting.

### Who was affected

Every IntelliJ, WebStorm or PyCharm user who cleaned that row. One reported
it. The fix cannot restore what was lost. A backup such as Time Machine is the
only way back.

### What changed

[`DevScanner`](https://github.com/jithin-sabu/purge-app/blob/v1.5.0/purge/Services/DevScanner.swift)
targets only the Caches folder.
[`DeletionSafetyPolicy.evaluate`](https://github.com/jithin-sabu/purge-app/blob/v1.5.0/purge/Services/DeletionSafetyPolicy.swift)
refuses `Application Support/JetBrains` and every descendant before any
allowlist rule runs, so it can never be scanned, sized or deleted. Three tests
pin it.

### What would have caught it earlier

Treating anything under `Application Support` as not a cache unless an entry
proves otherwise. The allowlist audit above (#103) went through the whole list
on that principle.

## 2026-07-25: Spotlight and 29 other items were Safe to Clean although cleaning them had visible consequences

**Reported:** [#10](https://github.com/jithin-sabu/purge-app/issues/10). **Fixed:** commit [`c265a95`](https://github.com/jithin-sabu/purge-app/commit/c265a9585f29fe551fb68641065db0e17efa9207), shipped in v1.3.0 (2026-08-02). **Affected:** v1.1.0 to v1.2.9.

### What happened

The user cleaned the Spotlight index from Safe to Clean, without reading the
whole list because it was labelled safe. Search then misbehaved until the
index was rebuilt. Nothing was lost, but they asked why something with an
immediate consequence sat in the one-click tier, and pointed at iCloud sync
caches as the same kind of thing.

### Who was affected

Anyone who ran Clean Safe Items or a scheduled clean. These entries had been
Safe since v1.1.0, the first release with the two labels.

### What changed

Thirty entries moved from Safe to Clean to Check First in
[`explanations.json`](https://github.com/jithin-sabu/purge-app/blob/v1.3.0/purge/Resources/explanations.json)
and
[`SafetyTierList.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.3.0/purge/Services/SafetyTierList.swift),
so they are no longer swept up by one-click or scheduled cleaning:

- Index rebuilds: Spotlight Search, Apple Photos, Apple Mail
- Sync re-verification: iCloud Data Sync, iCloud Drive Sync, Dropbox, Google
  Drive, Microsoft OneDrive, Contacts & Calendar Sync
- Lost history: Screen Time, Siri Suggestions
- Possible re-authentication: Apple ID, Sign in with Apple, 1Password

The full list is in the commit.

### What would have caught it earlier

A written definition of Safe, applied to every entry as a checklist rather
than as a tag. The definition now exists on the
[safety page](https://purgemac.com/safety): the app rebuilds it on its own and
you will not notice it is gone. Spotlight fails that test.

## 2026-07-12: Spotify cache cleanup took files a user kept there on purpose

**Reported:** [#3](https://github.com/jithin-sabu/purge-app/issues/3). **Fixed:** [#4](https://github.com/jithin-sabu/purge-app/pull/4), shipped in v1.2.8 (2026-07-13).

### What happened

The user ran a modified Spotify client that kept its added files inside
Spotify's cache folder. Purge listed the Spotify cache as Safe to Clean, and
cleaning it removed those files along with the cache. Purge did what its label
said. The gap was that there was no way to tell it to leave a folder alone.

### Who was affected

One user. Anyone else who keeps their own files inside a folder Purge treats
as a cache would have hit the same thing.

### What changed

Settings gained Excluded from Scans
([`ExcludedPathsStore.swift`](https://github.com/jithin-sabu/purge-app/blob/v1.2.8/purge/Services/ExcludedPathsStore.swift)).
An exclusion is a subtractive filter on top of the allowlist. It can only
remove a candidate from the results, never widen what Purge can touch.

### What would have caught it earlier

Nothing in Purge can know what a modified client keeps in a cache folder. The
lesson is that a deleter needs a per-path opt-out from the first release.
