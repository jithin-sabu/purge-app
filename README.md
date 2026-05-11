# Purge

**Free up your Mac. Safely.**

Purge scans your Mac for cache files and junk left behind by apps and development tools. It explains everything in plain English, tells you what is safe to delete, and never touches anything it is not sure about.

![Purge App Screenshot](screenshots/app.png)

---

## Features

- **App Caches** — Scans your Library/Caches folder and identifies every app cache with a friendly name and plain English explanation
- **Dev Tools** — Detects node_modules, Xcode DerivedData, Docker images, Python environments, Rust build folders, and more grouped by project
- **Safety Tags** — Every item is tagged Safe to Clean, Check First, Do Not Delete, or Not Sure before you delete anything
- **AI Identification** — Uses AI to identify unknown cache folders and explain them in plain English
- **Scheduled Cleaning** — Automatically cleans safe files on a schedule you control

---

## Download

👉 [Download the latest version](https://github.com/jithinsabumec/purge-app/releases/tag/v1.0.0)

---

## Installation

### Step 1: Download
Click the download link above and download `Purge.dmg`

### Step 2: Install
Open `Purge.dmg` and drag Purge to your Applications folder

### Step 3: Open for the first time

Since Purge is not on the Mac App Store, macOS will block 
it the first time you try to open it.

**Here is how to open it:**

1. Double click Purge to open it — macOS will block it and 
   show a warning, that is expected
2. Open **System Settings** on your Mac
3. Go to **Privacy & Security**
4. Scroll down to the **Security** section
5. You will see **"Purge was blocked from use because it is 
   not from an identified developer"**
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

## AI Identification (Recommended)

Purge can use AI to identify unknown cache folders. To enable this:

1. Get a free API key from [OpenRouter](https://openrouter.ai)
2. Open Purge and go to Settings
3. Paste your key in the AI Identification section

Purge only calls AI for folders it cannot identify on its own. Results are saved permanently so each folder is only ever looked up once.

---

## Requirements

- macOS 13.0 or later
- Full Disk Access permission

---

## Privacy

Purge never sends your files or file contents anywhere. The optional anonymous telemetry feature only sends cache folder names to help improve identification. You can preview exactly what is sent before it goes anywhere, and it is always opt in.

---


## Built by

Jithin Sabu · [LinkedIn](https://linkedin.com/in/jithinsabu) · [Send Feedback](mailto:design@jithinsabu.com)
