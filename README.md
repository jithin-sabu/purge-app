<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Purge app icon" />

  <h1>Purge</h1>

  <p><b>Free up your Mac. Safely.</b></p>

  <p>
    Clear out the cache and junk your Mac collects on its own.<br/>
    Open source, trash-by-default.
  </p>

<p>
  <a href="https://github.com/jithin-sabu/purge-app/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/jithin-sabu/purge-app/build.yml?branch=main&label=build" alt="Build status" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="License: MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="Latest release" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=orange" alt="Total downloads" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="GitHub stars" /></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>Download</b></a>
    &nbsp;·&nbsp;
    <a href="#installation">Install guide</a>
    &nbsp;·&nbsp;
    <a href="#build-from-source">Build from source</a>
    &nbsp;·&nbsp;
    <a href="docs/help.md">Help</a>
    &nbsp;·&nbsp;
    <a href="#security">Security</a>
  </p>

  <img src="Assets/github-hero.png" width="720" alt="Purge scanning a Mac for safe-to-clean cache" />

</div>

---

Your Mac quietly fills up with cache and junk you never see and never asked for. Purge finds it, marks what is safe, and clears it in one click.

> [!NOTE]
> Confirmed files move to the Trash, so you can put them back. An iOS Simulator device, and a Time Machine snapshot you remove from Overview, are deleted instead.

You do not need to understand any of it to use it. But if you ever want to check, every item carries a plain-English explanation and a safety label, so nothing gets touched that you cannot see and verify first.

---

## Features

Purge scans your Mac, labels what it recognizes, and moves confirmed files to the Trash.

Overview shows used, free, and total space from the disk, then App Caches, Dev Tools, Large Files, installed apps, and leftovers. It also lists local Time Machine snapshots and can remove the ones Time Machine is finished with. App Caches and Dev Tools are the safe clean. Large Files and the App Uninstaller wait for you to pick what goes. A menu bar mode can scan and clean the safe items without keeping the window open.

Safe to Clean is a known cache or a rebuildable folder. Check First may be safe, and a scheduled clean moves only Safe to Clean items. Folders Purge does not recognize stay off the list.

The full behavior, including settings, shortcuts, Siri, privacy, and what to do when a scan looks wrong, is in [Help](docs/help.md).

---

## Download

<div align="center">

<a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/badge/download-Purge-2EA043?style=flat&logo=apple&logoColor=white" alt="Download Purge" /></a>

</div>

---

## Installation

There are two ways to install Purge: with Homebrew if you live in the terminal, or by downloading the app directly. Both land in the same place.

### Install with Homebrew

```bash
brew install --cask jithin-sabu/tap/purge
```

This taps the repo and installs Purge in one step, and Homebrew verifies the download's checksum for you automatically.

### Install manually

The steps below walk through the direct download.

#### Step 1: Download

Click the download link above and download the `.dmg`.

#### Step 2: Verify your download (optional but recommended)

> [!TIP]
> Since Purge deletes files, verifying the checksum confirms your download is byte-for-byte the one that was published, with nothing altered in transit.

Each release includes a matching `.dmg.sha256` checksum file. Download both the `.dmg` and its `.dmg.sha256` file into the same folder, then in Terminal:

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

A result ending in `OK` means the file matches the published release.

#### Step 3: Install

Open the `.dmg` and drag Purge to your Applications folder.

#### Step 4: Open Purge

Double-click Purge to open it. Purge is notarized by Apple, so it opens normally with no extra steps.

#### Step 5: Grant Full Disk Access

Purge needs Full Disk Access to scan your cache folders.

1. Click **Open Privacy Settings** inside the app
2. Find Purge in the list
3. Turn on the toggle next to Purge
4. Come back to the app and click **I've granted access**

---

## Updating

Purge updates itself in place. Once a day it checks for a new version, and when one is available the update window appears with the release notes. Choose **Install Update** and Purge downloads it, verifies its signature, installs it, and relaunches. You don't need to visit the release page or drag anything.

Nothing is ever installed without your confirmation. You can also check whenever you like from the **About** screen, and if you'd rather Purge didn't check on its own, turn off **Check for updates automatically** in **Settings → Updates**.

Updates are delivered through [Sparkle](https://sparkle-project.org), the standard update framework for Mac apps outside the App Store. Each update is signed with a key that lives only on the developer's machine, and Purge refuses any download that doesn't carry a matching signature.

### Updating with Homebrew

If you installed through Homebrew, you can update from the terminal instead:

```bash
brew upgrade --cask purge
```

Either route is fine. Your settings, cleaning schedule, and history are kept whichever way you update; they live separately from the app. You won't need to grant Full Disk Access again either, since the permission stays with Purge.

You can also browse past versions on the [releases page](https://github.com/jithin-sabu/purge-app/releases) anytime.


---

## Build from source

Prefer to build Purge yourself instead of downloading the release? Here is how.

### Prerequisites

- macOS 13.0 or later
- **Xcode 16 or later** (from the Mac App Store). The project format and its default-actor-isolation build setting need Xcode 16; earlier versions won't open it
- [Node.js](https://nodejs.org) 18+ and npm, only needed if you want to regenerate brand icons

Dependencies are resolved by Swift Package Manager when you first build. The only one is [Sparkle](https://github.com/sparkle-project/Sparkle), which handles in-app updates.

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
xcodebuild test -project purge.xcodeproj -scheme purge -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

The signing flags matter: without a development certificate on the machine, the test build fails before a single test runs. Continuous integration builds the same way.

---

## Requirements

- macOS 13.0 or later
- Full Disk Access permission
- Xcode command-line tools (optional, for full iOS Simulator listing)

---

## Privacy

Purge runs entirely on your Mac. Scans, explanations, manual overrides, and cleanup history stay in local Application Support. Nothing is uploaded.

The one time Purge talks to the network is the update check: once a day it fetches a small XML file from GitHub to see whether a newer version is available. It sends nothing about you or your Mac, and you can turn it off in **Settings → Updates**.

Purge never reads or sends file contents.

---

## Security

Purge deletes files, so safety is the point. A few things worth knowing:

- **Trash by default**: Nothing is permanently deleted. Items move to the macOS Trash and can be restored until you empty it.
- **Allowlist-based deletion**: Only paths that match an explicit safety allowlist are ever eligible for cleanup. Anything Purge does not recognize is never touched.
- **You choose what goes**: Purge shows what is reclaimable and you decide what to clear.
- **Open source**: The full deletion logic, including the allowlist, is in this repo for you to read or build from source yourself.
- **Notarized by Apple**: The app is signed and notarized, so macOS can verify it hasn't been tampered with since release.
- **Signed updates**: In-app updates are verified against a signing key before they are installed. An update that isn't signed by that key is refused, so a compromised download can't become a compromised install.

Found a safety gap or a path that could be deleted when it shouldn't be? Please report it. See [SECURITY.md](SECURITY.md) for how.

---

## Contributing

Bug reports, safety findings, and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers how to set up the project and what makes a change easy to review. Anything touching the safety allowlist, the never-delete protections, or the scanning logic gets extra scrutiny and takes longer to review, which is deliberate.

Security issues are the exception: report those privately through [SECURITY.md](SECURITY.md) rather than opening an issue.

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