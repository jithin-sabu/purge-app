# Purge

**Free up your Mac. Safely.**

Purge scans your Mac for cache files and junk left behind by apps and development tools. Every item gets a plain-English explanation, a safety label, and recovery guidance before you delete anything. One-click cleanup only touches items marked **Safe to Clean**.

https://github.com/jithinsabumec/purge-app/raw/main/screenshots/Purge-Demo.mp4

---

## Features

### App Caches

Scans `~/Library/Caches`, sandbox container caches, and common system junk:

- Per-app cache folders with friendly names, brand icons, and plain-English explanations
- **System Junk** — iPhone backups, application logs, crash reports, macOS installers, font cache
- Duplicate cache locations for the same app merged into a single row
- Results stream in as they are found — no frozen scan screen

### Dev Tools

Three sections in one view:

- **Global dev tool caches** — Xcode (Derived Data, Archives, DeviceSupport), Homebrew, npm, pnpm, Yarn, CocoaPods, Gradle, Flutter, Docker Desktop, VS Code, Cursor, JetBrains, Cargo, Terraform, and more
- **iOS Simulators** — unused simulator runtimes grouped together (booted simulators are skipped)
- **Developer projects** — `node_modules`, Python virtual environments, Rust `target`, Flutter build output, Xcode `Pods`, Android `.gradle`, and other artifacts grouped by project

Control which projects appear with **Consider stale after** in Settings (1 month to 2 years, or Show all).

### Safety labels

Every item is tagged before you delete anything:

| Label | Meaning |
|-------|---------|
| **Safe to Clean** | Known cache or rebuildable artifact — safe to remove |
| **Check First** | May be safe, but could cause inconvenience |
| **Do Not Delete** | Passwords, credentials, or critical data — leave it alone |
| **Not Sure** | Could not be identified — Purge will not auto-clean these |

Filter chips: **All**, **Safe to Clean**, and **Check First** (the last includes both Check First and Do Not Delete items). Sort by size, date modified, or name.

Right-click any row to **Recategorize**, **Reset to automatic**, or delete with extra confirmation.

### Cleaning

- **Clean Safe Items** — one-click cleanup from the sidebar or menu bar; only Safe to Clean items, with git and lockfile checks
- **Clean Selected** — pick specific rows, review in a confirmation sheet, then delete
- **Scheduled cleaning** — enable in Settings; choose frequency (weekly, monthly, or every 3 months) and how long app caches must sit untouched (30 days to 12 months). Purge sends a local reminder and cleans safe items when you open the app

### More

- **First-run onboarding** — walks through permissions, preferences, your first scan, and a safe clean
- **Menu bar companion** — recoverable space at a glance, quick open, and **Clean Safe Files Now**
- **Manual categories** — your overrides are saved locally and always take priority over automatic identification
- **Git and lockfile checks** — warns before deleting near uncommitted changes or missing reinstall files

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

## How Purge identifies folders

Purge uses a local, hand-curated database — no cloud AI, no file contents uploaded. Resolution order:

1. **Your manual overrides** — any category you set yourself always wins
2. **Legacy local cache** — previously identified folders from older versions (`ai_cache.json`)
3. **Bundled database** — a curated `explanations.json` ships with the app
4. **Safety tier list** — pattern-based rules for common folder names
5. **Not Sure** — anything that does not match; Purge never auto-cleans these

---

## Requirements

- macOS 13.0 or later
- Full Disk Access permission
- Xcode command-line tools (optional, for full iOS Simulator listing)

---

## Privacy

Purge runs entirely on your Mac. Scans, explanations, manual overrides, and cleanup history stay in local Application Support — nothing is uploaded.

Purge never reads or sends file contents. There is no telemetry or analytics in the current release.

---

## Built by

Jithin Sabu · [LinkedIn](https://linkedin.com/in/jithinsabu) · [Send Feedback](mailto:design@jithinsabu.com)
