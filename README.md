<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Purge app icon" />

  <h1>Purge</h1>

  <p><b>Free up your Mac. Safely.</b></p>

  <p>
    Clear out the cache and junk your Mac collects on its own.<br/>
    Open source, trash-by-default.
  </p>

<p>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple&logoColor=white" alt="Platform: macOS 13+" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="License: MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="Latest release" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=brightgreen" alt="Total downloads" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="GitHub stars" /></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>⬇ Download</b></a>
    &nbsp;·&nbsp;
    <a href="#installation">Install guide</a>
    &nbsp;·&nbsp;
    <a href="#build-from-source">Build from source</a>
    &nbsp;·&nbsp;
    <a href="#security">Security</a>
  </p>

  <img src="Assets/purge-scr.png" width="720" alt="Purge scanning a Mac for safe-to-clean cache" />

</div>

---

Your Mac quietly fills up with cache and junk you never see and never asked for. Purge finds it, marks what is safe, and clears it in one click. Nothing is ever deleted permanently; everything moves to the Trash, so anything can come back.

You do not need to understand any of it to use it. But if you ever want to check, every item carries a plain-English explanation and a safety label, so nothing gets touched that you cannot see and verify first.

---

## Features

### App Caches

Scans `~/Library/Caches`, sandbox container caches, and common system junk:

- Per-app cache folders with friendly names, brand icons, and a plain-English explanation if you want to read it
- System Junk like application logs, crash reports, macOS installers, font cache
- Duplicate cache locations for the same app merged into a single row
- Results stream in as they are found

### Dev Tools

Three sections in one view:

- **Global dev tool caches**: Xcode (Derived Data, Archives, DeviceSupport), Homebrew, npm, pnpm, Yarn, CocoaPods, Gradle, Flutter, Docker Desktop, VS Code, Cursor, JetBrains, Cargo, Terraform, and more
- **iOS Simulators**: unused simulator runtimes grouped together (booted simulators are skipped)
- **Developer projects**: `node_modules`, Python virtual environments, Rust `target`, Flutter build output, Xcode `Pods`, Android `.gradle`, and other artifacts grouped by project

In **Settings → Developer Projects**, choose **Consider stale after** (1 month to 2 years, or Show all) to control which project folders appear.

### Large Files

Find space-hogging personal files without digging through folders:

- Scans **Documents**, **Desktop**, **Downloads**, **Movies**, **Music**, and **Pictures**
- Skips managed libraries (Photos, iMovie, Music, and similar) and hidden folders
- Filter by **size** (5 MB to 1 GB) and **last used** (any time up to over 1 year ago)
- Category chips for videos, audio, images, PDFs, archives, documents, and other files
- Sort by size, date, or name; select files and review before deleting
- **Quick Look** preview and **Reveal in Finder** from each row
- Deletions move files to **Trash**, so nothing is permanently erased

Large Files is separate from cache cleanup: these are your personal files, not rebuildable caches.

### Safety labels

Purge assigns a safety label to every item it recognizes:

| Label | Meaning |
|-------|---------|
| **Safe to Clean** | Known cache or rebuildable artifact, safe to remove |
| **Check First** | May be safe, but could cause inconvenience |

Filter with **All**, **Safe to Clean**, or **Check First** (⌘1–⌘3). Sort by size, date modified, or name.

Unidentified folders are left out of the list entirely. Purge only shows what it knows about.

The labels and explanations are there to be checked, not read cover to cover. Clean the safe items in one click and move on, or open the reasoning behind any single row first. Either way is fine.

### Cleaning

- **Clean Safe Items**: one-click cleanup from the sidebar; only Safe to Clean items, with git and lockfile checks
- **Clean Selected**: pick specific rows, review in a confirmation sheet, then delete
- **Clean Safe Files Now**: same safe cleanup from the menu bar
- **Scheduled cleaning**: in **Settings → Cleaning Schedule**, enable **Run automatic cleaning**, choose **How often** (weekly, monthly, or every 3 months) and **Untouched for** (30 days to 12 months). Purge sends a local reminder and cleans safe items when you open the app, so the cleanup keeps happening without you thinking about it
- All deletions move items to **Trash**, not permanent removal

### Settings

- **Appearance**: Light, Dark, or System
- **Cleaning Schedule**: automatic safe cleanup with frequency, staleness threshold, and next-clean date
- **Developer Projects**: stale-project threshold for developer artifact scanning

### More

- **First-run onboarding**: welcome, permissions (Full Disk Access and optional login item), auto-clean preference, first scan, results review, and a safe clean walkthrough
- **Menu bar companion**: recoverable space at a glance, quick open, scan/clean actions, and all-time cleaned total
- **Disk summary**: sidebar shows used/free space and how much is safe to recover
- **Scan All**: rescans App Caches and Dev Tools together (⇧⌘R)
- **Update check**: the About screen checks GitHub releases and points you to the latest version

---

## Download

<div align="center">

<a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/badge/download-Purge-2EA043?style=flat&logo=apple&logoColor=white" alt="Download Purge" /></a>

</div>

---

## Installation

### Step 1: Download

Click the download link above and download `Purge.dmg`.

### Step 2: Verify your download (optional but recommended)

Each release includes a `Purge.dmg.sha256` checksum file. Since Purge is an app that deletes files, you may want to confirm the DMG you downloaded is exactly the one that was published, with nothing altered in transit.

Download both `Purge.dmg` and `Purge.dmg.sha256` into the same folder, then in Terminal:

```bash
cd ~/Downloads
shasum -a 256 -c Purge.dmg.sha256
```

A result of `Purge.dmg: OK` means the file matches the published release.

### Step 3: Install

Open `Purge.dmg` and drag Purge to your Applications folder.

### Step 4: Open for the first time

Since Purge is not on the Mac App Store, macOS will block it the first time you try to open it.

**Here is how to open it:**

1. Double-click Purge to open it. macOS will block it and show a warning; that is expected
2. Open **System Settings** on your Mac
3. Go to **Privacy & Security**
4. Scroll down to the **Security** section
5. You will see **"Purge was blocked from use because it is not from an identified developer"**
6. Click **Open Anyway**
7. Enter your Mac password if asked
8. Click **Open** in the final confirmation

You only need to do this once. After that it opens normally.

### Step 5: Grant Full Disk Access

Purge needs Full Disk Access to scan your cache folders.

1. Click **Open Privacy Settings** inside the app
2. Find Purge in the list
3. Turn on the toggle next to Purge
4. Come back to the app and click **I've granted access**

---

## Updating

Purge isn't on the Mac App Store, so it doesn't update itself automatically. Instead, it checks for you and makes updating a quick manual swap.

### Checking for a new version

Open the **About** screen inside Purge and use **Check for Updates**. It compares your version against the latest GitHub release. If a newer one exists, it points you to the release page so you can download it. This is a notifier only: it doesn't download or install the update for you.

You can also just visit the [releases page](https://github.com/jithin-sabu/purge-app/releases/latest) anytime.

### Installing the update

1. Download the latest `Purge.dmg` from the release page
2. Open it and drag Purge into your Applications folder
3. When asked, choose **Replace** to overwrite the old version

That's it. Your settings, cleaning schedule, and history are kept; they live separately from the app, so replacing the app doesn't touch them. You won't need to grant Full Disk Access again either; the permission stays with Purge.

One thing to expect: because the app is unsigned, the first time you open a freshly downloaded update macOS may block it again, the same as the very first install. If that happens, use the same **Open Anyway** step from [Step 4](#step-4-open-for-the-first-time) above. After that one click it opens normally.

---

## Build from source

Prefer to build Purge yourself instead of downloading the release? Here is how.

### Prerequisites

- macOS 13.0 or later
- **Xcode 15 or later** (from the Mac App Store)
- [Node.js](https://nodejs.org) 18+ and npm, only needed if you want to regenerate brand icons

### Step 1: Clone the repo

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
```

### Step 2: Build and run

Open the project in Xcode and run:

```bash
open purge.xcodeproj
```

Then select the **purge** scheme and press **⌘R**.

Or build straight from the command line:

```bash
# Build a Debug app
xcodebuild -project purge.xcodeproj -scheme purge -configuration Debug build

# Build a Release app
xcodebuild -project purge.xcodeproj -scheme purge -configuration Release build
```

The built `Purge.app` is written under Xcode's DerivedData folder (the build output ends with its path).

### Optional: regenerate brand icons

The app cache icons are generated from [simple-icons](https://simpleicons.org). To rebuild them:

```bash
npm install
npm run generate:icons
```

### Running the tests

```bash
xcodebuild -project purge.xcodeproj -scheme purge -destination 'platform=macOS' test
```

---

## Requirements

- macOS 13.0 or later
- Full Disk Access permission
- Xcode command-line tools (optional, for full iOS Simulator listing)

---

## Privacy

Purge runs entirely on your Mac. Scans, explanations, manual overrides, and cleanup history stay in local Application Support. Nothing is uploaded.

Purge never reads or sends file contents.

---

## Security

Purge deletes files, so safety is the point. A few things worth knowing:

- **Trash by default**: nothing is permanently deleted. Items move to the macOS Trash and can be restored until you empty it.
- **Allowlist-based deletion**: only paths that match an explicit safety allowlist are ever eligible for cleanup. Anything Purge does not recognize is never touched.
- **You choose what goes**: Purge shows what is reclaimable and you decide what to clear.
- **Open source**: the full deletion logic, including the allowlist, is in this repo for you to read or build from source yourself.

Found a safety gap or a path that could be deleted when it shouldn't be? Please report it. See [SECURITY.md](SECURITY.md) for how.

---

## License

Purge is released under the [MIT License](LICENSE). You are free to use, read, modify, and distribute it.

---

## Support

Purge is free. If it saved you some disk space, you can chip in toward the running costs from the **About** screen inside the app, or directly at [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu).
<div align="center">

<a href="https://buymeacoffee.com/jithinsabu"><img src="https://img.shields.io/badge/support-Buy_me_a_coffee-FFDD00?style=flat&logo=buymeacoffee&logoColor=white" alt="Buy me a coffee" /></a>

</div>

---


<div align="center">

**Jithin Sabu**

<a href="https://jithinsabu.com"><img src="https://img.shields.io/badge/jithinsabu.com-black?style=flat&logo=safari&logoColor=white" alt="Website" /></a>
<a href="https://linkedin.com/in/jithinsabu"><img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white" alt="LinkedIn" /></a>
<a href="https://x.com/sabu_jithin"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="X" /></a>
<a href="mailto:design@jithinsabu.com"><img src="https://img.shields.io/badge/Email-EA4335?style=flat&logo=gmail&logoColor=white" alt="Email" /></a>

</div>