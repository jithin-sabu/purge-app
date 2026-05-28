# Purge

**Free up your Mac. Safely.**

Purge scans your Mac for cache files and junk left behind by apps and development tools. Every item gets a plain-English explanation and a safety label before you delete anything. One-click cleanup only touches items marked **Safe to Clean**.

![Purge demo](screenshots/Purge-Demo.gif)

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

In **Settings → Dev Tools**, choose **Consider stale after** (1 month to 2 years, or Show all) to control which project folders appear.

### Safety labels

Purge uses two labels you will see in the app:

| Label | Meaning |
|-------|---------|
| **Safe to Clean** | Known cache or rebuildable artifact — safe to remove |
| **Check First** | May be safe, but could cause inconvenience |

Filter with **All**, **Safe to Clean**, or **Check First**. Sort by size, date modified, or name.

Unidentified folders are left out of the list entirely — Purge only shows what it knows about.

Row badges call out extra context when relevant: **Can be rebuilt**, **Check support files**, **Local changes nearby**, and **Manual category** (when you override an item yourself). Right-click any row to recategorize or reset to automatic.

### Cleaning

- **Clean Safe Items** — one-click cleanup from the sidebar; only Safe to Clean items, with git and lockfile checks
- **Clean Selected** — pick specific rows, review in a confirmation sheet, then delete
- **Clean Safe Files Now** — same safe cleanup from the menu bar
- **Scheduled cleaning** — in **Settings → Cleaning Schedule**, enable **Run automatic cleaning**, choose **How often** (weekly, monthly, or every 3 months) and **Untouched for** (30 days to 12 months). Purge sends a local reminder and cleans safe items when you open the app

### More

- **First-run onboarding** — permissions, auto-clean preference, first scan, and a safe clean walkthrough
- **Menu bar companion** — recoverable space at a glance, quick open, and safe cleanup
- **Disk summary** — sidebar shows used/free space and how much is safe to recover
- **Scan All** — rescans App Caches and Dev Tools together (⇧⌘R)

---

## Download

👉 [Download the latest version](https://github.com/jithinsabumec/purge-app/releases/tag/v1.1.1)

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

## Requirements

- macOS 13.0 or later
- Full Disk Access permission
- Xcode command-line tools (optional, for full iOS Simulator listing)

---

## Privacy

Purge runs entirely on your Mac. Scans, explanations, manual overrides, and cleanup history stay in local Application Support — nothing is uploaded.

Purge never reads or sends file contents.

---

## Built by

Jithin Sabu · [LinkedIn](https://linkedin.com/in/jithinsabu) · [Send Feedback](mailto:design@jithinsabu.com)
