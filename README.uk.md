[English](README.md) | [简体中文](README.zh-CN.md) | [Русский](README.ru.md) | Українська | [العربية](README.ar.md) | [Türkçe](README.tr.md)

<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Іконка застосунку Purge" />

  <h1>Purge</h1>

  <p><b>Звільніть місце на Mac. Безпечно.</b></p>

  <p>
    Безкоштовний нативний застосунок для Mac з відкритим кодом, який прибирає кеш і сміття,<br/>
    що накопичуються на Mac самі собою. Файли за замовчуванням потрапляють у Кошик, тож їх можна повернути.
  </p>

<p>
  <a href="https://purgemac.com"><img src="https://img.shields.io/badge/website-purgemac.com-blueviolet?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjEwIi8+PHBhdGggZD0iTTIgMTJoMjAiLz48cGF0aCBkPSJNMTIgMmExNS4zIDE1LjMgMCAwIDEgNCAxMCAxNS4zIDE1LjMgMCAwIDEtNCAxMCAxNS4zIDE1LjMgMCAwIDEtNC0xMCAxNS4zIDE1LjMgMCAwIDEgNC0xMHoiLz48L3N2Zz4K" alt="Вебсайт" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/jithin-sabu/purge-app/build.yml?branch=main&label=build" alt="Статус збірки" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="Ліцензія: MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="Остання версія" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=orange" alt="Усього завантажень" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="Зірки на GitHub" /></a>
</p>

<p>
  <a href="https://trendshift.io/repositories/64435" target="_blank"><picture><source media="(prefers-color-scheme: dark)" srcset="https://trendshift.io/api/badge/repositories/64435?theme=dark"><img src="https://trendshift.io/api/badge/repositories/64435?theme=light" alt="jithin-sabu/purge-app | Trendshift" width="250" height="55"/></picture></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>Завантажити</b></a>
    &nbsp;·&nbsp;
    <a href="#встановлення">Інструкція зі встановлення</a>
    &nbsp;·&nbsp;
    <a href="#збирання-з-вихідного-коду">Збирання з вихідного коду</a>
    &nbsp;·&nbsp;
    <a href="#безпека">Безпека</a>
  </p>

  <img src="Assets/github-hero.png" width="720" alt="Purge шукає на Mac кеш, який безпечно очистити" />

</div>

---

Ваш Mac непомітно заповнюється кешем і сміттям, яких ви не бачите й про які не просили. Purge знаходить їх, позначає, що безпечно видаляти, і прибирає одним клацанням. Файли переміщуються в Кошик, тож їх можна повернути.

> [!NOTE]
> Інтерфейс Purge поки що доступний англійською, спрощеною китайською, російською, турецькою та арабською мовами, тож на Mac з українською мовою системи застосунок буде англійською. Тому назви кнопок, вкладок і пунктів меню тут залишено англійською — так, як ви побачите їх у застосунку. Якщо цей текст десь розходиться з англійським README, правильним є англійський.

## Встановлення

Purge працює на macOS 13 і новіших.

**Через Homebrew**

```bash
brew install --cask purge
```

**Або завантажте вручну**

1. Завантажте `.dmg` з [останнього релізу](https://github.com/jithin-sabu/purge-app/releases/latest).
2. Відкрийте його й перетягніть Purge до папки «Програми».
3. Відкрийте Purge. Застосунок нотаріально засвідчено Apple, тож він відкривається без додаткових кроків.

<details>
<summary>Перевірити завантаження (необов'язково)</summary>

До кожного релізу додано файл `.dmg.sha256`. Завантажте його в ту саму папку, що й `.dmg`, і виконайте:

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

Якщо результат закінчується на `OK`, файл точно збігається з опублікованим.

</details>

**«Повний доступ до диска» не обов'язковий.** Без нього Purge сканує App Caches і Dev Tools. З ним Purge також знаходить кеші застосунків з App Store, великі файли, встановлені застосунки й залишки видалених застосунків. Purge запитає про це наприкінці першого запуску, а вимкнути доступ можна будь-коли в Системних параметрах.

## Можливості

- **Overview**: куди поділося місце на диску, і всі елементи Safe to Clean переміщуються в Кошик за один раз
- **App Caches**: кеші застосунків, журнали, звіти про збої й залишки інсталяторів macOS
- **Dev Tools**: кеші Xcode, Homebrew, npm, Docker та інших, симулятори й папки збирання на кшталт `node_modules` у проєктах, з якими ви вже не працюєте
- **Large Files**: великі файли, дублікати, віртуальні машини й локальні моделі ШІ, з Quick Look перед видаленням
- **App Uninstaller**: видаляє застосунок разом із його кешами, налаштуваннями та іншими залишками
- **Очищення за розкладом**: прибирає елементи Safe to Clean щотижня, щомісяця або за вашим розкладом
- **Рядок меню, Швидкі команди й Finder**: необов'язковий значок у рядку меню, дії для Швидких команд і пункт **Uninstall with Purge** у контекстному меню Finder
- **П'ять мов інтерфейсу**: англійська, спрощена китайська, російська, турецька й арабська

Кожну функцію, налаштування й сполучення клавіш описано на сторінці [Purge in detail](docs/features.md) (англійською).

## Безпека

Purge видаляє файли, тому безпека на першому місці.

- **Кошик за замовчуванням.** Файли й папки переміщуються в Кошик, а Purge ніколи його не очищує. Небагато речей видаляється назавжди, і Purge повідомляє про це там, де ви їх вибираєте: симулятори iOS і їхні середовища виконання, Metal Toolchain для Xcode, локальні знімки Time Machine, моделі Apple Intelligence та інструменти чи застосунки, які ви вирішили видалити через їхній менеджер пакетів. [Повний список](docs/features.md#what-goes-to-the-trash-and-what-is-removed-for-good) (англійською).
- **Лише за списком дозволеного.** Purge очищує тільки місця зі свого списку безпечних і не чіпає того, чого не розпізнає. Усі вони перелічені на [сторінці безпеки](https://purgemac.com/safety/).
- **Мітки, які можна перевірити.** Кожен елемент позначено як Safe to Clean або Check First і має пояснення простою мовою. Очищення одним клацанням і за розкладом бере лише елементи Safe to Clean.
- **Помічник із правами root вимкнено за замовчуванням.** Невеликий помічник, що працює від root і потрібен для застосунків, встановлених адміністратором, вимкнено, доки ви його не ввімкнете. Його вихідний код лежить у `PurgeHelper/`.
- **Конфіденційність.** Purge працює лише на вашому Mac і не використовує ШІ. Єдине звернення до мережі — щоденна перевірка оновлень, яку можна вимкнути.
- **Відкритий код і підпис.** Уся логіка видалення — у цьому репозиторії. Застосунок нотаріально засвідчено Apple, а будь-яке оновлення без підпису ключем розробника Purge відхиляє.

Знайшли шлях, який Purge може видалити, хоча не повинен? Повідомте про це приватно, як описано в [SECURITY.md](SECURITY.md).

## Часті запитання

**Чи можна скасувати очищення?**
Так, для всього, що потрапило в Кошик: поверніть це з Кошика, доки не очистили його. **Settings → Updates and History → Cleaning history** показує, що куди пішло. Те, що видалено назавжди, повернути не можна, але частину цього Xcode і Purge можуть завантажити знову.

**Чи потрібен Purge «Повний доступ до диска»?**
Ні. Без нього доступні App Caches і Dev Tools. З ним — ще Large Files, App Uninstaller і залишки.

**Як оновити Purge?**
Purge раз на день перевіряє оновлення й показує список змін, перш ніж щось встановити. У **Settings → Updates and History** можна ввімкнути автоматичне встановлення або вимкнути перевірку. Якщо ви встановлювали через Homebrew, виконайте `brew upgrade --cask purge`. [Докладніше про оновлення](docs/features.md#updating) (англійською).

**Чи надсилає Purge щось із мого Mac?**
Лише запит перевірки оновлень, у якому є версія Purge і нічого про вас чи ваш Mac. [Докладніше про конфіденційність](docs/features.md#privacy) (англійською).

**Як видалити Purge?**
Виберіть **Uninstall Purge…** у меню Purge. Purge вимкне все, що запускає у фоні, і перемістить себе в Кошик. [Докладніше про видалення](docs/features.md#uninstalling) (англійською).

## Збирання з вихідного коду

Знадобляться macOS 13 або новіша та Xcode 26 або новіший.

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
open purge.xcodeproj
```

Виберіть схему **purge** і натисніть **⌘R**. У **Signing & Capabilities** виберіть свою команду або **Sign to Run Locally**. Збирання й тести з командного рядка описано в [CONTRIBUTING.md](CONTRIBUTING.md#building-and-testing) (англійською).

## Участь у розробці

Звіти про помилки, знахідки щодо безпеки й пул-реквести вітаються. Почніть із [CONTRIBUTING.md](CONTRIBUTING.md). Зміни в тому, що Purge може видалити, перевіряються суворіше, і це зроблено навмисно.

## Ліцензія

MIT. Див. [LICENSE](LICENSE).

## Підтримка

Purge безкоштовний. Якщо він звільнив вам місце, можете підтримати проєкт на екрані **About** у застосунку або через [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu).

<div align="center">

<a href="https://buymeacoffee.com/jithinsabu"><img src="https://img.shields.io/badge/support-Buy_me_a_coffee-FFDD00?style=flat&logo=buymeacoffee&logoColor=white" alt="Buy me a coffee" /></a>

</div>

---

<div align="center">

**Jithin Sabu**

<a href="https://jithinsabu.com"><img src="https://img.shields.io/badge/jithinsabu.com-black?style=flat&logo=safari&logoColor=white" alt="Вебсайт" /></a>
<a href="https://linkedin.com/in/jithinsabu"><img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white" alt="LinkedIn" /></a>
<a href="https://x.com/sabu_jithin"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="X" /></a>
<a href="mailto:jithin@purgemac.com"><img src="https://img.shields.io/badge/Email-EA4335?style=flat&logo=gmail&logoColor=white" alt="Email" /></a>

</div>
