<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Purge app icon" />

  <h1>Purge</h1>

  <p><b>Free up your Mac. Safely.</b></p>

  <p>English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.ru.md">Русский</a> | <a href="README.uk.md">Українська</a> | <a href="README.ar.md">العربية</a> | <a href="README.tr.md">Türkçe</a></p>

  <p>
    A free, open-source native Mac app that clears the cache and junk your Mac piles up on its own.<br/>
    Files go to the Trash by default, so you can put them back.
  </p>

<p>
  <a href="https://purgemac.com"><img src="https://img.shields.io/badge/website-purgemac.com-blueviolet?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjEwIi8+PHBhdGggZD0iTTIgMTJoMjAiLz48cGF0aCBkPSJNMTIgMmExNS4zIDE1LjMgMCAwIDEgNCAxMCAxNS4zIDE1LjMgMCAwIDEtNCAxMCAxNS4zIDE1LjMgMCAwIDEtNC0xMCAxNS4zIDE1LjMgMCAwIDEgNC0xMHoiLz48L3N2Zz4K" alt="Website" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/jithin-sabu/purge-app/build.yml?branch=main&label=build" alt="Build status" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="License: MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="Latest release" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=orange" alt="Total downloads" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="GitHub stars" /></a>
</p>

<p>
  <a href="https://trendshift.io/repositories/64435" target="_blank"><picture><source media="(prefers-color-scheme: dark)" srcset="https://trendshift.io/api/badge/repositories/64435?theme=dark"><img src="https://trendshift.io/api/badge/repositories/64435?theme=light" alt="jithin-sabu/purge-app | Trendshift" width="250" height="55"/></picture></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>Download</b></a>
    &nbsp;·&nbsp;
    <a href="#installation">Install guide</a>
    &nbsp;·&nbsp;
    <a href="#build-from-source">Build from source</a>
    &nbsp;·&nbsp;
    <a href="#security">Security</a>
  </p>

  <img src="Assets/github-hero.png" width="720" alt="Purge scanning a Mac for safe-to-clean cache" />

</div>

---

Your Mac quietly fills up with cache and junk you never see and never asked for. Purge finds it, marks what is safe, and clears it in one click. Files go to the Trash, so you can put them back.

## Installation

Purge needs macOS 13 or later.

**With Homebrew**

```bash
brew install --cask purge
```

**Or download it**

1. Download the `.dmg` from the [latest release](https://github.com/jithin-sabu/purge-app/releases/latest).
2. Open it and drag Purge to Applications.
3. Open Purge. It is notarized by Apple, so it opens with no extra steps.

<details>
<summary>Check your download (optional)</summary>

Each release has a `.dmg.sha256` file. Download it into the same folder as the `.dmg`, then run:

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

A result ending in `OK` means the file is exactly the one that was published.

</details>

**Full Disk Access is optional.** Without it, Purge scans App Caches and Dev Tools. With it, Purge also finds App Store apps' caches, large files, installed apps and leftovers from deleted apps. Purge asks at the end of the first run, and you can turn it off anytime in System Settings.

## Features

- **Overview**: see where your disk space went, and move every Safe to Clean item to the Trash at once
- **App Caches**: app caches, logs, crash reports and leftover macOS installers
- **Dev Tools**: caches from Xcode, Homebrew, npm, Docker and more, simulators, and build folders like `node_modules` in projects you no longer work on
- **Large Files**: big files, duplicates, virtual machines and local AI models, with Quick Look before anything goes
- **App Uninstaller**: removes an app together with its caches, settings and other leftovers
- **Scheduled cleaning**: clears Safe to Clean items weekly, monthly or on your own schedule
- **Menu bar, Shortcuts and Finder**: an optional menu bar companion, Shortcuts actions, and Uninstall with Purge in Finder's right-click menu
- **Five languages**: English, Simplified Chinese, Russian, Turkish and Arabic

Every feature, setting and keyboard shortcut is described in [Purge in detail](docs/features.md).

## Security

Purge deletes files, so safety comes first.

- **Trash by default.** Files and folders go to the Trash, and Purge never empties it. A few things are removed for good, and Purge says so where you pick them: iOS simulators and their runtimes, Xcode's Metal Toolchain, Time Machine local snapshots, the Apple Intelligence models, and tools or apps you choose to remove with their package manager. [The full list](docs/features.md#what-goes-to-the-trash-and-what-is-removed-for-good).
- **Allowlist only.** Purge cleans only places on its safety allowlist and never touches what it doesn't recognise. The [safety page](https://purgemac.com/safety/) lists every one.
- **Labels you can check.** Every item is marked Safe to Clean or Check First and comes with a plain-language explanation. One-click and scheduled cleans take only Safe to Clean items.
- **Root helper off by default.** A small helper that runs as root, for apps an administrator installed, stays off until you turn it on. Its source is in `PurgeHelper/`.
- **Private.** Purge runs entirely on your Mac and doesn't use AI. The only network call is a daily update check, which you can turn off.
- **Open source and signed.** All the deletion logic is in this repo. The app is notarized by Apple, and Purge refuses any update that isn't signed by the developer's key.

Found a path Purge could delete when it shouldn't? Report it privately through [SECURITY.md](SECURITY.md).

## FAQ

**Can I undo a clean?**
Yes, for anything that went to the Trash: put it back from the Trash until you empty it. **Settings → Updates and History → Cleaning history** shows what went where. Items removed for good can't be put back, though Xcode and Purge can download some of them again.

**Does Purge need Full Disk Access?**
No. Without it you get App Caches and Dev Tools. With it you also get Large Files, the App Uninstaller and leftovers.

**How do I update Purge?**
Purge checks once a day and shows the release notes before it installs anything. You can let it install updates on its own, or turn the checks off, in **Settings → Updates and History**. With Homebrew, run `brew upgrade --cask purge`. [More about updating](docs/features.md#updating).

**Does Purge send anything off my Mac?**
Only the update check, which sends the Purge version and nothing about you or your Mac. [More about privacy](docs/features.md#privacy).

**How do I uninstall Purge?**
Choose **Uninstall Purge…** in the Purge menu. Purge turns off everything it runs in the background, then moves itself to the Trash. [More about uninstalling](docs/features.md#uninstalling).

## Build from source

You need macOS 13 or later and Xcode 26 or later.

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
open purge.xcodeproj
```

Select the **purge** scheme and press **⌘R**. In **Signing & Capabilities**, choose your own team or **Sign to Run Locally**. [CONTRIBUTING.md](CONTRIBUTING.md#building-and-testing) covers command-line builds and tests.

## Contributing

Bug reports, safety findings and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Changes to what Purge can delete get extra review, and that is deliberate.

## License

MIT. See [LICENSE](LICENSE).

## Support

Purge is free. If it saved you some space, you can chip in from the **About** screen in the app or at [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu).

<div align="center">

<a href="https://buymeacoffee.com/jithinsabu"><img src="https://img.shields.io/badge/support-Buy_me_a_coffee-FFDD00?style=flat&logo=buymeacoffee&logoColor=white" alt="Buy me a coffee" /></a>

</div>

---

<div align="center">

**Jithin Sabu**

<a href="https://jithinsabu.com"><img src="https://img.shields.io/badge/jithinsabu.com-black?style=flat&logo=safari&logoColor=white" alt="Website" /></a>
<a href="https://linkedin.com/in/jithinsabu"><img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white" alt="LinkedIn" /></a>
<a href="https://x.com/sabu_jithin"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="X" /></a>
<a href="mailto:jithin@purgemac.com"><img src="https://img.shields.io/badge/Email-EA4335?style=flat&logo=gmail&logoColor=white" alt="Email" /></a>

</div>