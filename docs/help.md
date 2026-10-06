# Purge help

Purge finds cache, developer build files, large files, and leftover app files on your Mac, and labels what it recognizes. Confirmed files go to the Trash. Simulator devices and removed Time Machine snapshots are deleted instead. Those sections say so.

<a id="overview"></a>

## Overview

The sidebar starts with Overview, then groups App Caches and Dev Tools under Clean, and Large Files and App Uninstaller under Review. Settings and About sit at the bottom. The summary under them shows how much is already in the Trash, and the size of each scan tab.

The bar at the top of Overview is the whole disk. Purge reads used, free, and total from the volume, so they match System Settings. Each byte is counted once. An app cache counts under App Caches, and the app row keeps only what is left. Overview calls the rest everything else.

The rows under the bar are App Caches, Dev Tools, Large Files, installed apps, and leftovers from deleted apps. A row shows its size and its share of the disk. Click it to open that tab. A row that still needs Full Disk Access says so and stays locked. Hover a finished row to see when it was scanned.

Opening the window scans whatever has no results yet, one category at a time, in this order. App Caches and Dev Tools, then Large Files, then installed apps, then leftovers. Scan Everything runs every category again, from the File menu or with Shift-Command-R. On Overview, Command-R does the same thing. Without Full Disk Access, Large Files, apps, and leftovers stay out of that scan.

<a id="time-machine"></a>

### Time Machine snapshots

Overview also lists local Time Machine snapshots. Finder hides them, and macOS counts them as System Data. Time Machine saves one about every hour so you can get files back without a backup disk. The row shows how many there are and the date of the oldest. macOS reports no size, so Purge shows none.

Remove deletes the snapshots Time Machine is finished with. It keeps the newest snapshot, and the snapshot from the last backup to a disk. Those two are how Time Machine plans the next backup. Remove needs no password and no Full Disk Access. The snapshot is deleted, and the Trash has no copy to restore. Free space returns over a few seconds, once the disk has settled. If the newest snapshot is more than a day old, or a removal leaves some behind, the row points at Disk Utility. Purge leaves update snapshots off the list, because it cannot delete them.

<a id="app-caches"></a>

## App caches

App Caches scans `~/Library/Caches` and sandbox container caches. Each row is one known cache, with the app's name, a brand icon when Purge has one, the size, and a short explanation of what the folder is and how it comes back.

The same app can keep cache in more than one place. Purge merges those locations into one row. The scan adds rows as it finds them.

The same tab lists application logs, crash reports, the font cache, and downloaded macOS installers. The installer is Check First, because you may still want it for a USB installer. Purge empties logs and the user cache folder by moving the files inside them. The folders themselves stay.

Purge leaves out a folder with no entry.

<a id="dev-tools"></a>

## Dev tools

Dev Tools shows tool caches, then iOS Simulators, then Developer Projects.

**Tool caches.** These are global caches for tools Purge recognizes. Among them are Xcode Derived Data, archives, and device support, Homebrew, npm, pnpm, Yarn, Bun, CocoaPods, Gradle, Maven, Flutter, Docker, VS Code, Cursor, JetBrains, Cargo, Go, and Terraform. Only tools with an entry appear. Docker containers, Xcode archives, and device support are Check First.

**Orphaned Git Worktrees.** Checkouts made by Cursor, Codex, Conductor, T3 Code, and Claude Code appear here only after their repository no longer lists them. Purge hides a worktree that Git still lists, one a terminal or agent is working inside, and one Cursor has open.

**iOS Simulators.** These are simulator devices that are shut down. Purge skips a device that is booted right now. Removing one runs `simctl delete` on that device and the apps and data on it. The simulator runtime stays installed. The Trash cannot restore the device. A device Xcode can no longer run is Safe to Clean. A device used in the last month is Check First. A device with no recorded last use is Safe to Clean.

**Developer projects.** These are rebuildable folders inside projects you have not touched recently. The project types Purge detects are:

- Node
- Rust
- Flutter
- Xcode
- Python
- Android
- Elixir
- Swift Package
- Maven
- Gradle
- sbt
- .NET
- PHP
- Ruby
- Haskell, both Stack and Cabal
- Zig
- OCaml
- CMake
- Terraform
- Godot
- Unity
- Unreal

Each type offers the folders that toolchain rebuilds, such as `node_modules`, a Python virtual environment, Rust `target`, Flutter build output, CocoaPods `Pods`, or Android `.gradle`. The confirmation names the command or the steps that put the folder back.

In Settings, under Developer Projects, Consider stale after chooses which projects appear. The choices are 1 month, 3 months, 6 months, 12 months, 2 years, and Show all. The default is 6 months. Age is the last time anything in the project changed, including git activity. Purge ignores the dates on `node_modules` and `target`. A project with a terminal, a dev server, or a git command running inside it stays hidden, however old it is.

<a id="large-files"></a>

## Large files

Large Files finds personal files. It is separate from cache cleanup, and nothing here is cleaned unless you select it.

The scan covers Documents, Desktop, Downloads, Movies, Music, and Pictures. It needs Full Disk Access. It skips hidden folders and app bundles. It also skips the libraries that Photos, Photo Booth, iMovie, TV, Music, and GarageBand manage, and project folders such as `node_modules`, `Pods`, `DerivedData`, and build output. Deleting one file out of those trees breaks the project. Dev Tools removes them a folder at a time.

Search matches the file name, the folder it sits in, and its source label. Every word you type has to match. The size filter starts at larger than 100 MB. The steps are 5 MB, 50 MB, 100 MB, 250 MB, 500 MB, and 1 GB. The last-used filter offers Any time, Over 1 month ago, Over 3 months ago, Over 6 months ago, and Over 1 year ago. Last used is the later of when the file was opened and when it was modified.

Category chips are Videos, Audio, Images, PDFs, Archives, Documents, AI Models, and Other. A Duplicates chip appears once a scan finds identical copies. Sort by largest, smallest, newest, oldest, or name. Newest and oldest follow the last-used time on the row.

Each row can open a Quick Look preview and Reveal in Finder. Deletions move the files to the Trash.

<a id="duplicates"></a>

### Duplicates

A byte-for-byte scan groups identical files and shows how much space the extra copies use. Delete extra copies picks a copy to keep in each set and selects the rest. You can choose a different copy to keep before you confirm. The files stay until you review that list and confirm.

<a id="ai-models"></a>

### Local AI models

Models from Ollama and LM Studio show up under AI Models, one row per model, named the way you installed it. The row says Ollama or LM Studio instead of the folder on disk. For Ollama, the size is the bytes that model alone holds. Blobs shared with another model are not counted twice, and a delete removes the manifest plus the blobs nothing else uses.

<a id="uninstaller"></a>

## App uninstaller

Dragging an app to the Trash leaves caches, preferences, containers, saved state, logs, and login helpers on disk. The uninstaller removes the app and those files in one pass. It needs Full Disk Access. Without it, Purge would remove the app and leave the rest behind, so the tab stays locked.

The list is the apps in Applications and in `~/Applications`. Purge skips system apps and itself. Each tile shows the space an uninstall would free, which is the app plus the leftovers that can be removed. Sort by largest, smallest, name, or recently used. Recently used is the last time you opened the app. Purge offers size order only after every app has been measured, and forgets that order when you quit.

Select one or more apps. The review sheet lists every path, with its size and a safety label, grouped as the application, Application Support, containers, group containers, caches, saved state, logs, preferences, launch agents, and launch daemons.

Matching is strict, so uninstalling one app cannot take files shared with another app from the same vendor. An exact bundle id or app group arrives checked and labeled Safe to Clean. A name-only match arrives unchecked and labeled Check First. Purge keeps a file another installed app still uses, and the review says so.

Purge asks a running app to quit, and only gracefully. If it will not quit, that app stays installed and the rest of the batch continues. Purge moves confirmed items to the Trash.

<a id="leftovers"></a>

### Leftovers

When a scan finds files from apps that are no longer installed, the tab gains a Leftovers section. Those files are app data. The missing app will not rebuild them. Purge labels them Check First and waits for you to confirm the review.

Review leftovers when an app is deleted, in Settings, is off by default. Turn it on and a small watcher notices when an app leaves Applications or `~/Applications`, even while Purge is quit. Purge then opens on that app's leftovers and waits. Confirm or dismiss, and that review closes. The status line under the switch says whether the watcher is running. If macOS has stopped it, the line says so and offers the fix.

<a id="protected-apps"></a>

### Admin-locked apps

Some apps were installed by an administrator, and macOS will not move them to the Trash on its own. Remove admin-locked apps without a password, in Settings, registers a helper. Turning it on waits for approval in System Settings. Items still go to the Trash. You can turn the helper off at any time. Until it is on, a clean that hits one of these apps explains why and offers to set the helper up.

<a id="safety-labels"></a>

## Safety labels

Every item Purge recognizes gets one of two labels.

**Safe to Clean.** This is a known cache or a rebuildable artifact.

**Check First.** It may be safe, but removing it can cost you time or data you still want. Examples are a cloud-sync cache, a Docker container, a project you might still need, and a name-only uninstall match.

The list only shows those two labels. Purge hides a path it does not recognize. Paths that must stay, such as iPhone and iPad backups, are absent from the allowlist, so they never reach the list.

On App Caches and Dev Tools, filter with All, Safe to Clean, or Check First. The shortcuts are Command-1, Command-2, and Command-3. Sort by largest, smallest, newest, oldest, or name.

On the All filter, Select All selects the Safe to Clean rows only. A second step names the Check First rows and how much they hold. That second click is what selects them. On the Safe to Clean or Check First filter, Select All selects every visible row. Scheduled cleaning, Clean Safe Items, and the menu bar never touch a Check First row.

Right-click a scan result and choose Exclude from scans to keep that path out of later scans. Reveal in Finder is on the same menu.

If a project folder is missing the file that says how to reinstall it, Purge stops and shows "Missing reinstall instructions" before the clean. A later reinstall might not match the versions you had. Delete anyway continues, and Cancel stops.

If a project has changes that are not in git yet, Purge stops and shows "You have unsaved code changes nearby". Clean anyway continues, and Pause stops.

<a id="cleaning"></a>

## Cleaning and the Trash

**Clean Selected.** This takes the rows you picked, shows them in a confirmation sheet, and then moves them. Git and reinstall checks run after you confirm.

**Clean Safe Items.** On Overview, this is the same action as Clean Safe Files in the menu bar and as a scheduled clean. All three move Safe to Clean items in App Caches and Dev Tools. Check First items, Large Files, and uninstalls stay where they are.

Purge moves files to the Trash. You put a file back from there until you empty the Trash. Two deletions skip the Trash.

- An iOS Simulator device is deleted with `simctl delete`. The device and its apps and data are gone. The runtime stays.
- A Time Machine snapshot removed from Overview is deleted. The Trash has no copy to restore.

The About tab keeps a running total of bytes moved to the Trash.

When a clean finishes, any item that did not move is listed with a reason.

- Purge needs Full Disk Access to remove this.
- An administrator installed it, so it needs the secure removal helper.
- An app is still using it. Quit that app and clean again.
- macOS protects it and will not let it be removed.
- Purge left it alone to stay on the safe side.
- Another app you still have installed uses it too, so Purge kept it.
- It could not be removed. Try again.

Purge drops a file that was already gone from that list. The failure row offers Retry when the item was in use, when the helper is needed, or when the reason is unknown.

<a id="scheduled-cleaning"></a>

## Scheduled cleaning

In Settings, under Cleaning Schedule, turn on Run automatic cleaning and choose how often. Weekly, monthly, every 3 months, or a custom interval. Custom is a number of days, weeks, or months, from 1 to 365.

The clean runs the next time you launch Purge, or bring it forward, after the due time. macOS gives the app no background timer, so a quit app waits. The run moves the due date forward by one interval. A local notification is only a reminder. The status card shows the next clean and what the last one did.

With Launch Purge at login, that launch can happen at login and leave the window closed. Otherwise the clean waits until you open Purge.

The clean uses the same Safe to Clean rules as Clean Safe Items, including the stale-project threshold. If nothing matches, the schedule still counts as having run.

<a id="menu-bar"></a>

## Menu bar and on demand

Keep Purge in the menu bar, under Settings and Startup, switches between the two modes.

On demand is the default. Purge opens when you launch it and quits when you close the window.

Menu bar mode keeps Purge running after you close the window. The icon shows a dropdown.

- The safe-to-clean size, or "You're all clear", plus how long ago the scan ran.
- Clean Safe Files, when that figure is ready.
- Scan Caches & Dev Tools. This scan covers caches and dev tools only.
- Open Purge.
- Check for Updates.
- Quit.

The menu bar scans caches and dev tools when Purge launches. Clean Safe Files moves the same Safe to Clean items as the Overview button.

Two more switches appear only while the menu bar icon is on.

**Launch Purge at login.** Purge starts with the Mac and waits in the menu bar. No window opens until you click the icon.

**Hide Dock icon.** Purge runs from the menu bar only. Click the icon to open the window. The app menu is gone while the Dock icon is hidden, so Command-Q will not quit. Use Quit in the dropdown. Turning the menu bar icon off also turns these two switches off.

<a id="settings"></a>

## Settings

Settings is a tab, and also Settings in the app menu, or Command-Comma. The menu item waits until first-run setup is finished.

**Startup.** Keep Purge in the menu bar, launch at login, and hide the Dock icon.

**Deleted Apps.** When this is on, deleting an app in Finder opens Purge on that app's leftovers.

**Protected App Removal.** After one approval in System Settings, Purge can move an admin-locked app to the Trash.

**Appearance.** Light, Dark, or System.

**Cleaning Schedule.** Automatic safe cleaning, the interval, the next date, and the last result.

**Developer Projects.** How old a project must be before its rebuildable folders show up.

**Excluded from scans.** Folders you told Purge to skip, each with its current size, and a total. Add one with Add folder, or right-click a scan result and choose Exclude from scans. An exclusion only removes paths from the scan. Removing an exclusion puts the path back on the next scan, and only if the allowlist would have shown it anyway.

**Updates.** Check for updates automatically. The daily check is described under Updates.

**Cleaning History.** Automatic and manual cleans, newest first. The list keeps the last 100. The screen shows six until you choose Show all. Open one to see what moved to the Trash and what was skipped. Clear history deletes those records on this Mac. The Trash stays as it is, and the records are gone.

<a id="shortcuts"></a>

## Shortcuts, Siri, and Spotlight

| Shortcut | Action |
| --- | --- |
| Command-R | Scan the current tab. On Overview, scan every category. |
| Shift-Command-R | Scan every category, from any tab. |
| Command-1 | Show all items on App Caches or Dev Tools. |
| Command-2 | Show Safe to Clean. |
| Command-3 | Show Check First. |
| Command-Comma | Open Settings. |
| Command-Q | Quit Purge. |

Siri and Spotlight can run three actions. A Siri phrase has to include Purge. Spotlight also matches the words below with no app name. None of the three cleans Check First items, Large Files, or an app you have not confirmed.

**Scan for Junk.** Opens Purge on Overview, scans, and answers with how much in App Caches and Dev Tools is safe to clean. Nothing is cleaned. Phrases include "Scan for junk with Purge", "How much can Purge free", and "Free up space with Purge". Spotlight also matches junk, scan, storage, disk space, and cache.

**Clean Safe Junk.** This scans, then moves Safe to Clean items in App Caches and Dev Tools to the Trash. Phrases include "Clean junk with Purge" and "Clear caches with Purge". A loose request such as "free up space" stays on Scan for Junk.

**Uninstall an App.** Opens the uninstall review for the app you named, with that app and its leftovers listed. Nothing is removed until you confirm in the window. Phrases include "Uninstall [app] with Purge".

<a id="updates"></a>

## Updates

Purge checks for a new version once a day. When one is available, the update window shows the release notes. Install Update downloads it, checks its signature, installs it, and relaunches. Purge installs nothing until you confirm.

Check for Updates is in the app menu and on the About tab. Turn the daily check off under Settings, Updates. You can still check by hand.

Updates come through Sparkle. Each one is signed with a key that stays on the developer's machine. Purge refuses a download whose signature does not match.

If you installed with Homebrew, `brew upgrade --cask purge` updates from the terminal instead. Either route keeps your settings, cleaning schedule, and history, because they live outside the app. Full Disk Access stays with Purge across the update.

<a id="first-run"></a>

## First run

The first launch walks through a welcome, a first scan, the results, a safe clean, a short recap, and then Look deeper. Look deeper asks for Full Disk Access. It says what the permission unlocks. It also says Purge cleans only when you confirm, nothing leaves the Mac, and deletions go to the Trash. Simulator devices and Time Machine snapshots are the two deletions that skip the Trash. Those are described under Dev tools and Overview. Not now finishes setup without the permission. App Caches and Dev Tools already work. Large Files and the uninstaller wait.

About can replay this walkthrough.

<a id="about"></a>

## About

About shows the version and build date, and a lifetime total of bytes moved to the Trash. Before the first clean it says nothing has been cleaned yet.

From the same screen you can check for updates, open the deletion allowlist on GitHub, report a bug, request a feature, replay the first-run walkthrough, or open the support link.

<a id="privacy"></a>

## Privacy

Purge runs on your Mac. Scans, explanations, settings, and cleaning history stay in local Application Support and preferences. Nothing is uploaded.

The one network request is the update check. Once a day Purge fetches a small XML file from GitHub to see if a newer version exists. The request sends nothing about you or your Mac. Turn it off under Settings, Updates.

Purge decides what to clean from names, paths, and sizes. It never sends file contents. The duplicate scan compares bytes on disk and keeps the result on the Mac.

<a id="troubleshooting"></a>

## Troubleshooting

<a id="full-disk-access"></a>

### Full Disk Access

App Caches and Dev Tools still scan, and skip folders macOS will not let Purge read. Large Files and the App Uninstaller stay locked, and their Overview rows say they need access. The sidebar notice and the Look deeper button open the same explanation. That screen is the only place Purge asks.

Grant it in System Settings, Privacy and Security, Full Disk Access. Turn Purge on, come back, and the locked scans start. If you grant it during the first-run ask, Purge scans from that screen and shows what the extra access found.

<a id="empty-scan"></a>

### An empty scan

A category can be empty for a few different reasons.

- Nothing on the Mac matched an entry Purge knows. Purge omits folders it does not recognize.
- The filter is Safe to Clean or Check First, and the other label has the rows.
- Developer projects are newer than Consider stale after, or a project is in use right now.
- Large Files is filtered by size, last used, category, or search.
- The path is under Excluded from scans.
- Full Disk Access is off, so Large Files, apps, and leftovers never ran.
- The menu bar scan covers caches and dev tools. Scan Everything in the window covers Large Files and apps too.

<a id="skipped-files"></a>

### Files skipped during a clean

The clean summary names each item that stayed, with one of the reasons in Cleaning and the Trash. The usual fixes are below.

- **Needs Full Disk Access.** Grant it, then retry. See Full Disk Access above.
- **Needs the secure removal helper.** Use Set Up Secure Removal on the failure, or turn the helper on under Settings, Protected App Removal.
- **In use.** Quit the app that has the file open, then retry.
- **Protected by macOS.** Purge cannot remove it. This is a file macOS has marked immutable, or a System Integrity Protection file.
- **Left alone on purpose.** The allowlist rejected it during the delete.
- **Kept for another app.** A second installed app still uses that file.
- **Could not be removed.** Retry. If it keeps failing, the failure row is the one to report.

A running app that refuses a graceful quit is left installed. The other apps in that uninstall still proceed.

<a id="free-space"></a>

### Free space that did not go up

Files moved to the Trash still count as used space. Overview reads used and free from the volume, same as System Settings, so those numbers drop when you empty the Trash, not when Purge finishes. The sidebar total is what is sitting in the Trash, including the iCloud Drive trash. Purge cannot empty the Trash.

A Time Machine snapshot is the other case. Remove deletes it. The free-space number can take a few seconds to update, and Purge reports a freed size only once the disk has stopped changing. If it cannot measure a gain, the row says what was removed and leaves the size off.

Simulator devices deleted from Dev Tools are also gone immediately, not sitting in the Trash. Their size leaves the Dev Tools total. The volume's free space should follow.
