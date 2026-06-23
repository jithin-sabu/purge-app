# Purge

**Free up your Mac. Safely.**

Purge scans your Mac for cache files and junk left behind by apps and development tools. Every item gets a plain-English explanation and a safety label before you delete anything. One-click cleanup only touches items marked **Safe to Clean**.

---


## Features

### App Caches

Scans `~/Library/Caches`, sandbox container caches, and common system junk:

- Per-app cache folders with friendly names, brand icons, and plain-English explanations
- **System Junk** — iPhone backups, application logs, crash reports, macOS installers, font cache
- Duplicate cache locations for the same app merged into a single row
- Results stream in as they are found

### Dev Tools

Three sections in one view:

- **Global dev tool caches** — Xcode (Derived Data, Archives, DeviceSupport), Homebrew, npm, pnpm, Yarn, CocoaPods, Gradle, Flutter, Docker Desktop, VS Code, Cursor, JetBrains, Cargo, Terraform, and more
- **iOS Simulators** — unused simulator runtimes grouped together (booted simulators are skipped)
- **Developer projects** — `node_modules`, Python virtual environments, Rust `target`, Flutter build output, Xcode `Pods`, Android `.gradle`, and other artifacts grouped by project

In **Settings → Developer Projects**, choose **Consider stale after** (1 month to 2 years, or Show all) to control which project folders appear.

### Large Files

Find space-hogging personal files without digging through folders:

- Scans **Documents**, **Desktop**, **Downloads**, **Movies**, **Music**, and **Pictures**
- Skips managed libraries (Photos, iMovie, Music, and similar) and hidden folders
- Filter by **size** (5 MB to 1 GB) and **last used** (any time up to over 1 year ago)
- Category chips for videos, audio, images, PDFs, archives, documents, and other files
- Sort by size, date, or name; select files and review before deleting
- **Quick Look** preview and **Reveal in Finder** from each row
- Deletions move files to **Trash** — nothing is permanently erased

Large Files is separate from cache cleanup: these are your personal files, not rebuildable caches.

### Safety labels

Purge assigns a safety label to every item it recognizes:

| Label | Meaning |
|-------|---------|
| **Safe to Clean** | Known cache or rebuildable artifact — safe to remove |
| **Check First** | May be safe, but could cause inconvenience |

Filter with **All**, **Safe to Clean**, or **Check First** (⌘1–⌘3). Sort by size, date modified, or name.

Unidentified folders are left out of the list entirely — Purge only shows what it knows about.

### Cleaning

- **Clean Safe Items** — one-click cleanup from the sidebar; only Safe to Clean items, with git and lockfile checks
- **Clean Selected** — pick specific rows, review in a confirmation sheet, then delete
- **Clean Safe Files Now** — same safe cleanup from the menu bar
- **Scheduled cleaning** — in **Settings → Cleaning Schedule**, enable **Run automatic cleaning**, choose **How often** (weekly, monthly, or every 3 months) and **Untouched for** (30 days to 12 months). Purge sends a local reminder and cleans safe items when you open the app
- All deletions move items to **Trash**, not permanent removal

### Settings

- **Appearance** — Light, Dark, or System
- **Cleaning Schedule** — automatic safe cleanup with frequency, staleness threshold, and next-clean date
- **Developer Projects** — stale-project threshold for developer artifact scanning


### More

- **First-run onboarding** — welcome, permissions (Full Disk Access and optional login item), auto-clean preference, first scan, results review, and a safe clean walkthrough
- **Menu bar companion** — recoverable space at a glance, quick open, scan/clean actions, and all-time cleaned total
- **Disk summary** — sidebar shows used/free space and how much is safe to recover
- **Scan All** — rescans App Caches and Dev Tools together (⇧⌘R)
- **Update check** — the About screen checks GitHub releases and points you to the latest version

---

## Download

👉 [Download the latest version](https://github.com/jithinsabumec/purge-app/releases/latest)

---

## Installation

### Step 1: Download

Click the download link above and download `Purge.dmg`.

### Step 2: Install

Open `Purge.dmg` and drag Purge to your Applications folder.

### Step 3: Open for the first time

Since Purge is not on the Mac App Store, macOS will block it the first time you try to open it.

**Here is how to open it:**

1. Double-click Purge to open it — macOS will block it and show a warning; that is expected
2. Open **System Settings** on your Mac
3. Go to **Privacy & Security**
4. Scroll down to the **Security** section
5. You will see **"Purge was blocked from use because it is not from an identified developer"**
6. Click **Open Anyway**
7. Enter your Mac password if asked
8. Click **Open** in the final confirmation

You only need to do this once. After that it opens normally.

### Step 4: Grant Full Disk Access

Purge needs Full Disk Access to scan your cache folders.

1. Click **Open Privacy Settings** inside the app
2. Find Purge in the list
3. Turn on the toggle next to Purge
4. Come back to the app and click **I've granted access**

---

## Build from source

Prefer to build Purge yourself instead of downloading the release? Here is how.

### Prerequisites

- macOS 13.0 or later
- **Xcode 15 or later** (from the Mac App Store)
- [Node.js](https://nodejs.org) 18+ and npm — only needed if you want to regenerate brand icons

### Step 1: Clone the repo

```bash
git clone https://github.com/jithinsabumec/purge-app.git
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

Purge runs entirely on your Mac. Scans, explanations, manual overrides, and cleanup history stay in local Application Support — nothing is uploaded.

Purge never reads or sends file contents.

---

## Support

Purge is free. If it saved you some disk space, you can chip in toward the running costs from the **About** screen inside the app, or directly at [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu).

---

## Built by

Jithin Sabu · [LinkedIn](https://linkedin.com/in/jithinsabu) · [X](https://x.com/sabu_jithin) · [Send Feedback](mailto:design@jithinsabu.com)
