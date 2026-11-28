[English](README.md) | 简体中文 | [Русский](README.ru.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | [Türkçe](README.tr.md)

<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Purge 应用图标" />

  <h1>Purge</h1>

  <p><b>释放 Mac 空间，安全第一。</b></p>

  <p>
    一款免费、开源的原生 Mac 应用，清理 Mac 自己悄悄积累的缓存和垃圾文件。<br/>
    文件默认移到废纸篓，随时可以放回原处。
  </p>

<p>
  <a href="https://purgemac.com"><img src="https://img.shields.io/badge/website-purgemac.com-blueviolet?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjEwIi8+PHBhdGggZD0iTTIgMTJoMjAiLz48cGF0aCBkPSJNMTIgMmExNS4zIDE1LjMgMCAwIDEgNCAxMCAxNS4zIDE1LjMgMCAwIDEtNCAxMCAxNS4zIDE1LjMgMCAwIDEtNC0xMCAxNS4zIDE1LjMgMCAwIDEgNC0xMHoiLz48L3N2Zz4K" alt="网站" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/jithin-sabu/purge-app/build.yml?branch=main&label=build" alt="构建状态" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="许可证：MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="最新版本" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=orange" alt="总下载量" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="GitHub Star 数" /></a>
</p>

<p>
  <a href="https://trendshift.io/repositories/64435" target="_blank"><picture><source media="(prefers-color-scheme: dark)" srcset="https://trendshift.io/api/badge/repositories/64435?theme=dark"><img src="https://trendshift.io/api/badge/repositories/64435?theme=light" alt="jithin-sabu/purge-app | Trendshift" width="250" height="55"/></picture></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>下载</b></a>
    &nbsp;·&nbsp;
    <a href="#安装">安装指南</a>
    &nbsp;·&nbsp;
    <a href="#从源码构建">从源码构建</a>
    &nbsp;·&nbsp;
    <a href="#安全">安全</a>
  </p>

  <img src="Assets/github-hero.png" width="720" alt="Purge 正在扫描 Mac 上可安全清理的缓存" />

</div>

---

> 本应用的简体中文界面基于 [@zihua-zhang](https://github.com/zihua-zhang) 的社区翻译（[Purge-zh](https://github.com/zihua-zhang/Purge-zh)）。如果本文与英文 README 有出入，请以英文 README 为准。
>
> Purge 现在支持英文、简体中文、俄文、土耳其文和阿拉伯文，并跟随 macOS 的系统语言。你也可以在“系统设置 > 通用 > 语言与地区 > 应用程序”中单独为 Purge 设置语言。

你的 Mac 会悄悄积累大量缓存和垃圾文件，你既看不到，也从没要求过它们存在。Purge 会找出这些文件，标出哪些是安全的，并一键清理。文件会移到废纸篓，所以你可以把它们放回去。

## 安装

Purge 需要 macOS 13 或更高版本。

**使用 Homebrew**

```bash
brew install --cask purge
```

**或直接下载**

1. 从[最新版本](https://github.com/jithin-sabu/purge-app/releases/latest)下载 `.dmg`。
2. 打开它，把 Purge 拖到“应用程序”文件夹。
3. 打开 Purge。它已通过 Apple 公证，无需额外步骤即可打开。

<details>
<summary>校验下载文件（可选）</summary>

每个版本都附带一个 `.dmg.sha256` 文件。把它下载到 `.dmg` 所在的文件夹，然后运行：

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

结果以 `OK` 结尾，说明文件与发布的版本完全一致。

</details>

**完全磁盘访问权限是可选的。** 没有它，Purge 会扫描应用缓存和开发工具。有了它，Purge 还能找到 App Store 应用的缓存、大文件、已安装的应用以及已删除应用的残留文件。Purge 会在首次运行结束时询问，你也可以随时在系统设置中关闭。

## 功能

- **概览**：看看磁盘空间都去哪了，并一次性把所有“可安全清理”的项目移到废纸篓
- **应用缓存**：应用缓存、日志、崩溃报告和残留的 macOS 安装器
- **开发工具**：Xcode、Homebrew、npm、Docker 等工具的缓存、模拟器，以及你已不再开发的项目中的 `node_modules` 等构建文件夹
- **大文件**：大文件、重复文件、虚拟机和本地 AI 模型，删除前可用 Quick Look 预览
- **应用卸载**：连同应用的缓存、设置和其他残留文件一起移除
- **定时清理**：每周、每月或按你设定的周期清理“可安全清理”的项目
- **菜单栏、快捷指令和访达**：可选的菜单栏小工具、快捷指令操作，以及访达右键菜单中的“使用 Purge 卸载”
- **五种语言**：英文、简体中文、俄文、土耳其文和阿拉伯文

每项功能、设置和键盘快捷键的说明都在 [Purge 详细说明](docs/features.md)（英文）中。

## 安全

Purge 会删除文件，所以安全永远放在第一位。

- **默认移到废纸篓。** 文件和文件夹会移到废纸篓，Purge 从不清空废纸篓。少数内容会被永久移除，Purge 会在你选择它们的地方注明：iOS 模拟器及其运行时、Xcode 的 Metal 工具链、Time Machine 本地快照、Apple 智能模型，以及你选择交给包管理器卸载的工具或应用。[完整列表](docs/features.md#what-goes-to-the-trash-and-what-is-removed-for-good)（英文）。
- **只清理白名单内的位置。** Purge 只清理安全白名单上的位置，从不碰它不认识的内容。[安全页面](https://purgemac.com/safety/)列出了每一个位置。
- **可核对的标签。** 每个项目都标为“可安全清理”或“先检查”，并附有通俗易懂的说明。一键清理和定时清理只会处理“可安全清理”的项目。
- **root 助手默认关闭。** 用于移除管理员安装的应用的小助手以 root 身份运行，在你开启之前一直关闭。它的源码在 `PurgeHelper/`。
- **注重隐私。** Purge 完全在你的 Mac 上运行，不使用 AI。唯一的网络请求是每天一次的更新检查，你可以关闭它。
- **开源且经过签名。** 所有删除逻辑都在这个仓库里。应用经过 Apple 公证，任何没有开发者密钥签名的更新都会被 Purge 拒绝。

发现 Purge 可能误删某个路径？请通过 [SECURITY.md](SECURITY.md) 私下报告。

## 常见问题

**清理之后还能撤销吗？**
移到废纸篓的内容可以：在你清空废纸篓之前，都可以把它们放回去。**设置 → 更新与历史记录 → 清理历史记录** 会显示每样东西去了哪里。被永久移除的内容无法放回，不过其中一部分可以由 Xcode 或 Purge 重新下载。

**Purge 需要完全磁盘访问权限吗？**
不需要。没有它，你可以使用应用缓存和开发工具。有了它，还可以使用大文件、应用卸载和残留文件。

**怎样更新 Purge？**
Purge 每天检查一次更新，并在安装前显示更新说明。你可以在 **设置 → 更新与历史记录** 中让它自动安装更新，或关闭检查。使用 Homebrew 的话，运行 `brew upgrade --cask purge`。[更多关于更新的说明](docs/features.md#updating)（英文）。

**Purge 会把任何东西发送出我的 Mac 吗？**
只有更新检查，它只发送 Purge 的版本号，不包含任何关于你或你的 Mac 的信息。[更多关于隐私的说明](docs/features.md#privacy)（英文）。

**怎样卸载 Purge？**
在 Purge 菜单中选择 **卸载 Purge…**。Purge 会关闭它在后台运行的所有项目，然后把自己移到废纸篓。[更多关于卸载的说明](docs/features.md#uninstalling)（英文）。

## 从源码构建

你需要 macOS 13 或更高版本，以及 Xcode 26 或更高版本。

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
open purge.xcodeproj
```

选择 **purge** scheme 并按 **⌘R**。在 **Signing & Capabilities** 中选择你自己的团队或 **Sign to Run Locally**。命令行构建和测试见 [CONTRIBUTING.md](CONTRIBUTING.md#building-and-testing)（英文）。

## 参与贡献

欢迎提交 bug 报告、安全问题和拉取请求。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。涉及 Purge 能删除哪些内容的改动会经过更严格的审查，这是有意为之。

## 许可证

MIT。详见 [LICENSE](LICENSE)。

## 支持

Purge 是免费的。如果它帮你节省了一些空间，你可以在应用内的“关于”界面，或通过 [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu) 支持一下。

<div align="center">

<a href="https://buymeacoffee.com/jithinsabu"><img src="https://img.shields.io/badge/support-Buy_me_a_coffee-FFDD00?style=flat&logo=buymeacoffee&logoColor=white" alt="Buy me a coffee" /></a>

</div>

---

<div align="center">

**Jithin Sabu**

<a href="https://jithinsabu.com"><img src="https://img.shields.io/badge/jithinsabu.com-black?style=flat&logo=safari&logoColor=white" alt="网站" /></a>
<a href="https://linkedin.com/in/jithinsabu"><img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white" alt="LinkedIn" /></a>
<a href="https://x.com/sabu_jithin"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="X" /></a>
<a href="mailto:jithin@purgemac.com"><img src="https://img.shields.io/badge/Email-EA4335?style=flat&logo=gmail&logoColor=white" alt="电子邮件" /></a>

</div>
