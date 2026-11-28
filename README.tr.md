[English](README.md) | [简体中文](README.zh-CN.md) | [Русский](README.ru.md) | [Українська](README.uk.md) | [العربية](README.ar.md) | Türkçe

<div align="center">

  <img src="Assets/purge-iOS-Default-1024x1024@1x.png" width="128" alt="Purge uygulama simgesi" />

  <h1>Purge</h1>

  <p><b>Mac'inizde yer açın. Güvenle.</b></p>

  <p>
    Mac'inizin kendiliğinden biriktirdiği önbellek ve gereksiz dosyaları temizleyen ücretsiz, açık kaynaklı, yerel bir Mac uygulaması.<br/>
    Dosyalar varsayılan olarak Çöp Sepeti'ne taşınır; böylece isterseniz geri alabilirsiniz.
  </p>

<p>
  <a href="https://purgemac.com"><img src="https://img.shields.io/badge/website-purgemac.com-blueviolet?logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjEwIi8+PHBhdGggZD0iTTIgMTJoMjAiLz48cGF0aCBkPSJNMTIgMmExNS4zIDE1LjMgMCAwIDEgNCAxMCAxNS4zIDE1LjMgMCAwIDEtNCAxMCAxNS4zIDE1LjMgMCAwIDEtNC0xMCAxNS4zIDE1LjMgMCAwIDEgNC0xMHoiLz48L3N2Zz4K" alt="Web sitesi" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/jithin-sabu/purge-app/build.yml?branch=main&label=build" alt="Derleme durumu" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/blob/main/LICENSE"><img src="https://img.shields.io/github/license/jithin-sabu/purge-app?color=blue" alt="Lisans: MIT" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/github/v/release/jithin-sabu/purge-app?label=latest&color=red" alt="Son sürüm" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/releases"><img src="https://img.shields.io/github/downloads/jithin-sabu/purge-app/total?label=downloads&color=orange" alt="Toplam indirme" /></a>
  <a href="https://github.com/jithin-sabu/purge-app/stargazers"><img src="https://img.shields.io/github/stars/jithin-sabu/purge-app?color=yellow" alt="GitHub yıldızları" /></a>
</p>

<p>
  <a href="https://trendshift.io/repositories/64435" target="_blank"><picture><source media="(prefers-color-scheme: dark)" srcset="https://trendshift.io/api/badge/repositories/64435?theme=dark"><img src="https://trendshift.io/api/badge/repositories/64435?theme=light" alt="jithin-sabu/purge-app | Trendshift" width="250" height="55"/></picture></a>
</p>

  <p>
    <a href="https://github.com/jithin-sabu/purge-app/releases/latest"><b>İndir</b></a>
    &nbsp;·&nbsp;
    <a href="#kurulum">Kurulum kılavuzu</a>
    &nbsp;·&nbsp;
    <a href="#kaynak-koddan-derleme">Kaynak koddan derle</a>
    &nbsp;·&nbsp;
    <a href="#g%C3%BCvenlik">Güvenlik</a>
  </p>

  <img src="Assets/github-hero.png" width="720" alt="Purge, Mac'te güvenle temizlenebilecek önbellekleri tarıyor" />

</div>

---

Mac'iniz zamanla hiç görmediğiniz ve istemediğiniz önbellek ve gereksiz dosyalarla sessizce dolar. Purge bunları bulur, hangilerinin güvenli olduğunu işaretler ve tek tıkla temizler. Dosyalar Çöp Sepeti'ne taşınır, yani geri alabilirsiniz.

## Kurulum

Purge, macOS 13 veya üstünü gerektirir.

**Homebrew ile**

```bash
brew install --cask purge
```

**Ya da indirerek**

1. [Son sürümden](https://github.com/jithin-sabu/purge-app/releases/latest) `.dmg` dosyasını indirin.
2. Açın ve Purge'ü Uygulamalar klasörüne sürükleyin.
3. Purge'ü açın. Apple tarafından onaylandığı (notarized) için ek bir adım gerekmeden açılır.

<details>
<summary>İndirmenizi doğrulayın (isteğe bağlı)</summary>

Her sürümde bir `.dmg.sha256` dosyası bulunur. Bu dosyayı `.dmg` ile aynı klasöre indirin ve şunu çalıştırın:

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

Sonuç `OK` ile bitiyorsa dosya, yayımlanan dosyanın birebir aynısıdır.

</details>

**Tam Disk Erişimi isteğe bağlıdır.** Bu izin olmadan Purge, Uygulama Önbellekleri ve Geliştirici Araçları'nı tarar. İzinle birlikte App Store uygulamalarının önbelleklerini, büyük dosyaları, yüklü uygulamaları ve silinmiş uygulamaların kalıntılarını da bulur. Purge bunu ilk çalıştırmanın sonunda sorar; izni istediğiniz zaman Sistem Ayarları'ndan kapatabilirsiniz.

## Özellikler

- **Genel Bakış**: disk alanınızın nereye gittiğini görün ve tüm "Güvenle Temizlenebilir" öğeleri tek seferde Çöp Sepeti'ne taşıyın
- **Uygulama Önbellekleri**: uygulama önbellekleri, günlükler, çökme raporları ve artakalan macOS yükleyicileri
- **Geliştirici Araçları**: Xcode, Homebrew, npm, Docker ve diğerlerinin önbellekleri, simülatörler ve artık üzerinde çalışmadığınız projelerdeki `node_modules` gibi derleme klasörleri
- **Büyük Dosyalar**: büyük dosyalar, kopyalar, sanal makineler ve yerel yapay zekâ modelleri; silmeden önce Göz At (Quick Look) ile önizleme
- **Uygulama Kaldırıcı**: bir uygulamayı önbellekleri, ayarları ve diğer kalıntılarıyla birlikte kaldırır
- **Zamanlanmış temizlik**: "Güvenle Temizlenebilir" öğeleri haftalık, aylık ya da kendi belirlediğiniz aralıkla temizler
- **Menü çubuğu, Kestirmeler ve Finder**: isteğe bağlı menü çubuğu simgesi, Kestirmeler eylemleri ve Finder'ın sağ tık menüsünde "Purge ile Kaldır"
- **Beş dil**: İngilizce, Basitleştirilmiş Çince, Rusça, Türkçe ve Arapça

Her özellik, ayar ve klavye kısayolu [Purge in detail](docs/features.md) sayfasında (İngilizce) anlatılır.

## Güvenlik

Purge dosya siler, bu yüzden güvenlik her şeyden önce gelir.

- **Varsayılan olarak Çöp Sepeti.** Dosya ve klasörler Çöp Sepeti'ne taşınır ve Purge Çöp Sepeti'ni asla boşaltmaz. Birkaç şey kalıcı olarak kaldırılır ve Purge bunları seçtiğiniz yerde belirtir: iOS simülatörleri ve çalışma zamanları, Xcode Metal Toolchain, yerel Time Machine anlık görüntüleri, Apple Intelligence modelleri ve paket yöneticisiyle kaldırmayı seçtiğiniz araçlar ya da uygulamalar. [Tam liste](docs/features.md#what-goes-to-the-trash-and-what-is-removed-for-good) (İngilizce).
- **Yalnızca izin listesi.** Purge yalnızca güvenlik izin listesindeki konumları temizler ve tanımadığı hiçbir şeye dokunmaz. [Güvenlik sayfası](https://purgemac.com/safety/) bu konumların hepsini listeler.
- **Kontrol edebileceğiniz etiketler.** Her öğe "Güvenle Temizlenebilir" ya da "Önce Kontrol Et" olarak işaretlenir ve sade bir açıklama taşır. Tek tıkla ve zamanlanmış temizlikler yalnızca "Güvenle Temizlenebilir" öğeleri alır.
- **Root yardımcısı varsayılan olarak kapalı.** Bir yöneticinin yüklediği uygulamalar için root olarak çalışan küçük yardımcı, siz açana kadar kapalı kalır. Kaynak kodu `PurgeHelper/` klasöründedir.
- **Gizlilik.** Purge tamamen Mac'inizde çalışır ve yapay zekâ kullanmaz. Tek ağ isteği, kapatabileceğiniz günlük güncelleme denetimidir.
- **Açık kaynak ve imzalı.** Tüm silme mantığı bu depodadır. Uygulama Apple tarafından onaylanmıştır ve Purge, geliştiricinin anahtarıyla imzalanmamış hiçbir güncellemeyi kabul etmez.

Purge'ün silmemesi gereken bir yolu silebileceğini mi fark ettiniz? [SECURITY.md](SECURITY.md) üzerinden gizlice bildirin.

## SSS

**Bir temizliği geri alabilir miyim?**
Çöp Sepeti'ne giden her şey için evet: Çöp Sepeti'ni boşaltana kadar geri koyabilirsiniz. **Ayarlar → Güncellemeler ve Geçmiş → Temizlik geçmişi** neyin nereye gittiğini gösterir. Kalıcı olarak kaldırılanlar geri konamaz, ancak bazılarını Xcode ve Purge yeniden indirebilir.

**Purge'ün Tam Disk Erişimi'ne ihtiyacı var mı?**
Hayır. Bu izin olmadan Uygulama Önbellekleri ve Geliştirici Araçları'nı kullanırsınız. İzinle Büyük Dosyalar, Uygulama Kaldırıcı ve kalıntılar da gelir.

**Purge'ü nasıl güncellerim?**
Purge günde bir kez denetler ve bir şey yüklemeden önce sürüm notlarını gösterir. **Ayarlar → Güncellemeler ve Geçmiş** bölümünden güncellemelerin kendiliğinden yüklenmesini açabilir veya denetimi kapatabilirsiniz. Homebrew ile `brew upgrade --cask purge` çalıştırın. [Güncelleme hakkında daha fazlası](docs/features.md#updating) (İngilizce).

**Purge, Mac'imden dışarı bir şey gönderir mi?**
Yalnızca güncelleme denetimi; bu da sadece Purge sürümünü gönderir, sizin veya Mac'iniz hakkında hiçbir şey göndermez. [Gizlilik hakkında daha fazlası](docs/features.md#privacy) (İngilizce).

**Purge'ü nasıl kaldırırım?**
Purge menüsünden **Purge'ü Kaldır…** seçeneğini seçin. Purge arka planda çalıştırdığı her şeyi kapatır, ardından kendini Çöp Sepeti'ne taşır. [Kaldırma hakkında daha fazlası](docs/features.md#uninstalling) (İngilizce).

## Kaynak koddan derleme

macOS 13 veya üstü ve Xcode 26 veya üstü gerekir.

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
open purge.xcodeproj
```

**purge** şemasını seçip **⌘R** tuşlarına basın. **Signing & Capabilities** bölümünde kendi ekibinizi veya **Sign to Run Locally** seçeneğini belirleyin. Komut satırından derleme ve testler [CONTRIBUTING.md](CONTRIBUTING.md#building-and-testing) dosyasında (İngilizce) anlatılır.

## Katkıda Bulunma

Hata raporları, güvenlik bulguları ve pull request'ler memnuniyetle karşılanır. [CONTRIBUTING.md](CONTRIBUTING.md) ile başlayın. Purge'ün neleri silebileceğini değiştiren katkılar daha sıkı incelenir; bu bilinçli bir tercihtir.

## Lisans

MIT. Bkz. [LICENSE](LICENSE).

## Destek

Purge ücretsizdir. Size yer kazandırdıysa, uygulamadaki **Hakkında** ekranından veya [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu) üzerinden destek olabilirsiniz.

<div align="center">

<a href="https://buymeacoffee.com/jithinsabu"><img src="https://img.shields.io/badge/support-Buy_me_a_coffee-FFDD00?style=flat&logo=buymeacoffee&logoColor=white" alt="Buy me a coffee" /></a>

</div>

---

<div align="center">

**Jithin Sabu**

<a href="https://jithinsabu.com"><img src="https://img.shields.io/badge/jithinsabu.com-black?style=flat&logo=safari&logoColor=white" alt="Web sitesi" /></a>
<a href="https://linkedin.com/in/jithinsabu"><img src="https://img.shields.io/badge/LinkedIn-0A66C2?style=flat&logo=linkedin&logoColor=white" alt="LinkedIn" /></a>
<a href="https://x.com/sabu_jithin"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="X" /></a>
<a href="mailto:jithin@purgemac.com"><img src="https://img.shields.io/badge/Email-EA4335?style=flat&logo=gmail&logoColor=white" alt="E-posta" /></a>

</div>
