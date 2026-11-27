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

Mac'iniz zamanla hiç görmediğiniz ve istemediğiniz önbellek ve gereksiz dosyalarla sessizce dolar. Purge bunları bulur, hangilerinin güvenli olduğunu işaretler ve tek tıkla temizler.

> [!NOTE]
> Dosya ve klasörler varsayılan olarak Çöp Sepeti'ne taşınır ve Purge Çöp Sepeti'ni asla boşaltmaz; yani kendiniz boşaltana kadar hepsini geri alabilirsiniz. Kalıcı olarak silinenler: Xcode'un `simctl` aracıyla kaldırılan iOS simülatörleri ve simülatör çalışma zamanları; `xcodebuild -deleteComponent` ile kaldırılan isteğe bağlı Xcode Metal Toolchain bileşeni (bir proje ihtiyaç duyduğunda Xcode tekrar indirir); `tmutil` ile silinen yerel Time Machine anlık görüntüleri (Purge en yenisini ve son yedeğinizden kalanı korur); Apple'ın varlık servisi üzerinden serbest bırakılan ve Purge'den yeniden indirilebilen macOS 27 Apple Intelligence modelleri; inceleme ekranında seçtiğinizde kendi paket yöneticisiyle kaldırılan komut satırı araçları ve Homebrew cask uygulamaları. Docker Desktop klasörü Çöp Sepeti'ne taşınır; Purge `docker system prune` çalıştırmaz.

Kullanmak için teknik ayrıntıları bilmeniz gerekmez. Ancak kontrol etmek isterseniz, her öğe sade bir açıklama ve güvenlik etiketi taşır; böylece önce görüp doğrulamadığınız hiçbir şeye dokunulmaz.

---

## Özellikler

### Genel Bakış

- **Alanınız nereye gitti**: Tüm disk için tek bir çubuk. Kullanılan, boş ve toplam alan doğrudan disk biriminden okunur; yani Sistem Ayarları ile birebir örtüşür. Uygulama Önbellekleri, Geliştirici Araçları, Büyük Dosyalar, yüklü uygulamalar ve silinmiş uygulamaların kalıntıları kendi bölümlerine sahiptir; kalan kısım "Diğer her şey" olarak gösterilir
- Her kategori için boyut ve disk payı satırı. İlgili sekmeyi açmak için satıra tıklayın
- **Diğer her şey** de açılabilir. Satıra tıkladığınızda içeriği gösteren bir sayfa açılır: alanla ilgili yapabileceklerinizi özetleyen dört değer ve her grubun en büyük klasörlerini kapladığı alana göre boyutlandırıp türüne göre renklendiren bir harita. Türler; başka bir uygulamadan boşaltabileceğiniz alan (Fotoğraflar, Mail, Steam, Çöp Sepeti), kendi dosyalarınız (projeler, belgeler), Purge'ün silmeyi güvenli görmediği için dokunmadığı veriler (liste dışı önbellekler, hiçbir yüklü uygulamanın sahiplenmediği veriler) ve macOS'in yönettiği alandır. Bir karenin üzerine gelerek adını görün, tıklayarak ne olduğunu inceleyin ve Finder'da Göster ya da ilgili uygulamanın temizleme yöntemini görün. Tamamen salt okunurdur; bu ekranda hiçbir dosya taşınmaz
- **Her Şeyi Tara** (⇧⌘R), Mac'in akıcı kalması için her kategoriyi sırayla tarar. Purge'ü açtığınızda da aynısını kendiliğinden yapar. Büyük Dosyalar, uygulama listesi ve kalıntılar için Tam Disk Erişimi gerekir. Bu izin olmadan da Purge, Uygulama Önbellekleri ve Geliştirici Araçları'nı tarar; macOS'in koruduğu korumalı alan (sandbox) önbelleklerini atlar
- Her bayt yalnızca bir kez sayılır: bir uygulamanın önbellek klasörü Uygulama Önbellekleri altında sayılır, uygulamanın altında tekrar sayılmaz
- **Sistem Verileri içinde gizli**: macOS'in Sistem Verileri olarak saydığı alan için kategorilerin altında bir kart yer alır. Yerel anlık görüntüleri **Time Machine anlık görüntüleri** satırından kaldırabilirsiniz; macOS 27'de Apple Intelligence modelleri de burada görünür
- **Apple Intelligence modelleri** (macOS 27, Apple Silicon): macOS'in Sistem Verileri altında tuttuğu ve kaldırma anahtarı sunmadığı cihaz içi modeller. Kaldır seçeneği bunları Apple'ın varlık servisi üzerinden serbest bırakır ve tekrar indirilmemeleri için bir kez onaylamanız gereken bir profil yükler. Yeniden İndir ise Sistem Ayarları'ndan profili kaldırmanızı ister, ardından Purge'ün kaldırdığı setleri Siri dilinizde macOS'ten tekrar ister. Gösterilen boyut Apple'ın bildirdiği değerdir; Purge diskin gerçekten geri verdiği alanı kaydeder. Kaldırma başarısız olursa **Ayrıntılar** ne deneyebileceğinizi ve macOS'in döndürdüğü tüm yanıtı gösterir; hiçbir şey kaldırılmadıysa düğme **Profili Kaldır** olarak görünür

### Uygulama Önbellekleri

`~/Library/Caches`, sandbox konteyner önbellekleri (Tam Disk Erişimi gerektirir) ve yaygın sistem çöplerini tarar:

- Okunaklı adlar, marka simgeleri ve isterseniz okuyabileceğiniz sade açıklamalarla uygulama bazlı önbellek klasörleri
- Uygulama günlükleri, çökme raporları, macOS yükleyicileri ve kalan macOS güncelleme dosyaları gibi Sistem Çöpleri
- Premiere Pro ve After Effects gibi yaratıcı uygulamalardan kalan büyük medya önbellekleri
- Aynı uygulamaya ait birden fazla önbellek konumu tek satırda birleştirilir
- Sonuçlar bulundukça anlık olarak listelenir

### Geliştirici Araçları

Tek görünümde beş grup:

- **Genel geliştirici aracı önbellekleri**: Xcode (Derived Data, Archives, DeviceSupport), Homebrew, npm, pnpm, Yarn, CocoaPods, Gradle, Dart ve Flutter pub önbelleği, Docker Desktop, VS Code, Cursor, JetBrains, Cargo, Terraform ve daha fazlası
- **iOS Simülatörleri**: Kapalı durumdaki her simülatör için ayrı bir satır. Çalışan simülatörler kapladıkları alan görünsün diye listelenir ancak seçilemez
- **Simülatör Çalışma Zamanları**: `simctl` aracının silinebilir olarak bildirdiği her çalışma zamanı için bir satır
- **Xcode Bileşenleri**: Tam bir Xcode kurulumunda yüklü görünüyorsa `xcodebuild -deleteComponent` ile kaldırılan isteğe bağlı Metal Toolchain (yaklaşık 900 MB)
- **Geliştirici projeleri**: Proje bazında gruplanmış `node_modules`, Python sanal ortamları, Rust `target`, Flutter derleme çıktıları, Xcode `Pods`, Android `.gradle` ve diğer derleme artıkları

Simülatörler, çalışma zamanları ve Xcode bileşenleri her zaman "Önce Kontrol Et" etiketlidir. Çöp Sepeti'ne taşınmaz, kalıcı olarak silinirler; bölüm başlıkları da bunu açıkça belirtir.

**Ayarlar → Temizleme** altında **Projeler şu süreden sonra eski sayılır** seçeneğini (1 aydan 2 yıla kadar veya Tümünü göster) kullanarak hangi projelerin görüneceğini belirleyebilirsiniz. Yaş, `node_modules` veya `target` tarihine göre değil, git etkinliği dahil projedeki en son değişikliğe göre ölçülür. İçinde aktif bir terminal, geliştirme sunucusu veya süren bir git komutu bulunan projeler hiçbir zaman listelenmez.

Geliştirici projeleri, **Ayarlar → Taranacak diğer klasörler** altına eklediğiniz klasör ve disklerde de aranır. Ana klasörünüzün dışında bulunan projeler her zaman "Önce Kontrol Et" olarak işaretlenir; böylece Güvenli Öğeleri Temizle veya zamanlanmış temizlik bunlara dokunmaz. Ana klasörünüz içindeki ek klasörlerde normal kurallar geçerlidir. Tam Disk Erişimi olmadan yalnızca ana klasörünüz içindeki ek klasörler taranır.

Yapay zeka kodlama araçlarının (Cursor, Codex, Conductor, T3 Code ve Claude Code) oluşturduğu Git worktree'leri yalnızca depoları artık onları listelemediğinde **Sahipsiz Git Worktree'leri** altında görünür. Git'in hâlâ kullandığı veya içinde bir terminalin ya da ajanın çalıştığı worktree ne kadar eski olursa olsun asla listelenmez.

### Büyük Dosyalar

Klasörlerin içinde kaybolmadan yer kaplayan kişisel dosyaları bulun:

- **Belgeler**, **Masaüstü**, **İndirilenler**, **Filmler**, **Müzik** ve **Resimler** klasörlerini, yalnızca sanal makineler için `~/Parallels` ve `~/Virtual Machines.localized` klasörlerini ve yalnızca iCloud'da tutabileceğiniz dosyalar için iCloud Drive klasörünü tarar
- Ayrıca **Ayarlar → Taranacak diğer klasörler** altına eklediğiniz, yalnızca Mac'inize bağlı disklerdeki klasör ve sürücüleri tarar; ağ paylaşımları veya bulut sürücüler taranmaz. Takılı olmayan bir diskin klasörü boş gösterilmez, adıyla birlikte atlanır. Mac veya ana klasör kopyaları, Time Machine yedekleri, uygulama paketleri ve Dropbox, Syncthing, Resilio Sync, ownCloud, Nextcloud ya da eski OneDrive klasörleri burada asla taranmaz. Purge bu servisleri işaret dosyalarından tanır; başka bir servisin eşitlediği klasörler yine taranabilir. Bu klasörlerdeki dosyalar ilgili diskin Çöp Sepeti'ne gider
- Taşıyıp yerine sembolik bağlantı koyduğunuz bir klasör (örneğin başka bir diske işaret eden `~/Documents`), bağlantı ana klasörünüz içinde veya `/Volumes` altındaki bağlı bir diskteyse hedefte taranır; dosyaları gerçek yollarıyla listelenir ve o diskin Çöp Sepeti'ne gider. `~/Library/CloudStorage`, ağ paylaşımı, tüm bir disk veya Mac kopyasına giden bağlantılar izlenmez ve tarama bağlantının nereye gittiğini bildirir. Klasör içindeki bağlantılar asla izlenmez
- Yönetilen arşivleri (Fotoğraflar, iMovie, Müzik vb.), gizli klasörleri ve `node_modules`, `Pods`, `DerivedData` gibi proje klasörlerini atlar. Bir bağımlılık ağacından tek dosya silmek kurulumu bozar; bu yüzden bunlar klasör bazında temizlenen Geliştirici Araçları sekmesinde yer alır
- **Arama**, siz yazdıkça dosya adına, bulunduğu klasöre ve kaynak etiketine göre listeyi filtreler
- **Boyut** (5 MB – 1 GB) ve **son kullanım** (herhangi bir zaman – 1 yıldan eski) filtreleri
- Video, ses, görsel, PDF, arşiv, belge, yapay zeka modelleri, sanal makineler ve diğer dosyalar için kategori etiketleri
- **Yinelenenler**: Bayt bazında tarama birebir aynı kopyaları bulur, gruplar ve tek kopya tutarsanız ne kadar alan açılacağını gösterir. **Yinelenenler** etiketi hepsini tek yerde toplar. **Fazla kopyaları sil** tüm sekmeyi tek seferde temizler; her grup için saklanacak bir kopya önerip kalanları Çöp Sepeti için işaretler, silmeden önce saklanacak kopyayı değiştirebilirsiniz. Siz inceleyip onaylamadan hiçbir şey silinmez
- Boyut, tarih veya ada göre sıralama; silmeden önce seçme ve inceleme
- Her satırdan **Göz At (Quick Look)** önizlemesi ve **Finder'da Göster**
- Silinen dosyalar **Çöp Sepeti'ne** taşınır; hiçbir şey kalıcı olarak yok edilmez
- **Yalnızca iCloud'da Tut**, bir iCloud dosyasının bu Mac'te kapladığı alanı boşaltır ve dosyayı iCloud'da saklar (Finder'daki İndirmeyi Kaldır ile aynı). **iCloud** etiketi burada da yer kaplayan eşitlenmiş dosyaları ve kazanılacak alanı listeler; işlem hem burada hem de her eşitlenmiş dosyanın sağ tık menüsünde yer alır. Dosya Finder'da bulut simgesiyle yerinde kalır ve açtığınızda yeniden indirilir. Purge bunu yalnızca iCloud'a tamamen yüklenmiş, eşitleme çakışması olmayan, "İndirilmiş Tut" olarak ayarlanmamış, sabit bağlantısız ve beş dakikadır değişmemiş dosyalar için sunar. İşlemden hemen önce tüm koşulları tekrar kontrol eder ve bir uygulamada açık dosyaları atlar. iCloud Drive klasöründeki dosyalar, Çöp Sepeti'ne atıldıklarında diğer cihazlarınızdan da silinecekleri için asla Çöp Sepeti'ne önerilmez. Güvenli Öğeleri Temizle veya zamanlanmış temizlik kapsamına hiç girmez

Büyük Dosyalar önbellek temizliğinden ayrıdır: bunlar yeniden oluşturulabilen önbellekler değil, kişisel dosyalarınızdır.

#### Geri yükleme kalıpları, sanal makineler ve yarım kalan indirmeler

Bazı büyük dosyalar ne olduklarını açıklayan bir etiket taşır. Tam açıklama için üzerine gelin.

- **Geri yükleme kalıbı**: Genellikle 15–25 GB boyutundaki macOS `.ipsw` dosyası. Yalnızca bir Mac, cihaz veya sanal makine kurarken gerekir.
- **Sanal makine**: Parallels (`.pvm`), UTM (`.utm`) veya VMware Fusion (`.vmwarevm`) paketi. Tek satır olarak görünür ve içindeki bir disk dosyası değil, paket bütün olarak Çöp Sepeti'ne gider. Uygulama hâlâ yüklüyse etiket sanal makineyi uygulamanın içinden kaldırmanızı önerir. Uygulaması açık olan veya kilit dosyası tutan bir sanal makine, uygulamadan çıkana kadar listelenmez.
- **Yarım kalan indirme**: `.crdownload`, `.part`, Parallels'in `.prlupd-part` dosyaları ve doğrudan İndirilenler içindeki Safari `.download` paketleri.

#### Yerel yapay zeka modelleri

İndirilen modeller çoğu zaman bir Mac'teki en büyük dosyalardır ve kolayca unutulurlar. Büyük Dosyalar altında **Yapay Zeka Modelleri** kategorisinde, kurduğunuz adla ve indiren uygulama/kitaplık konumuyla her model tek satır olarak görünür. Purge şu depoları tanır: **Ollama**, **LM Studio**, **Hugging Face Hub** önbelleği (`~/.cache/huggingface/hub`; `HF_HOME` ve `HF_HUB_CACHE` yalnızca kabuk profilinde değil, uygulamalar için ayarlandığında dikkate alınır; Ollama'nın `OLLAMA_MODELS` değeri de Ollama'nın Mac uygulamasının okuduğu gibi `launchctl setenv` üzerinden okunur), swift-transformers, modelleri `~/Library/Caches/huggingface` altında tutan uygulamalar, **PyTorch Hub**, **Whisper**, **GPT4All**, **Jan**, **DiffusionBee** ve **Draw Things**. `~/Library/Caches`, `~/Library/Application Support` ve `~/.cache` içinde bilinen bir depoya ait olmayan 100 MB üzeri ağırlık dosyaları da hangi uygulamanın indirdiğini anlayabilmeniz için bulundukları klasörle listelenir.

Purge, Ollama'nın içerik adresli depolama yapısını anlar; bu yüzden bir modelin boyutu başka bir modelle paylaşılan blokları değil, yalnızca gerçekten geri kazanılacak baytları sayar. Hugging Face modelleri tüm önbellek klasörü olarak ele alınır; iki anlık görüntünün paylaştığı blok bir kez sayılır ve diğerinin altından asla silinmez. Modeller her zaman Çöp Sepeti'ne gider ve asla Güvenli Öğeleri Temizle ya da zamanlanmış temizlik kapsamına girmez. Bir uygulama kendi yüklü model listesini tutuyorsa satır, uygulamanın modeli hâlâ yüklü gösterebileceğini belirtir.

### Uygulama Kaldırıcı

Bir uygulamayı Çöp Sepeti'ne sürüklemek parçalarının çoğunu geride bırakır: önbellekler, tercihler, konteynerler, kayıtlı durum, günlükler, çerezler, web sitesi verileri ve oturum açma yardımcıları diskte birikir. Uygulama Kaldırıcı uygulamayı ve bu kalıntıları tek seferde temizler.

- Sistem uygulamaları ve Purge hariç, **Uygulamalar**, **~/Applications**, taktığınız disklerin kökündeki **Applications** klasörü ve **Ayarlar → Purge uygulamaları nerede arar** altına eklediğiniz klasörlerdeki uygulamaları listeler. Her kart kaldırmanın ne kadar yer açacağını (uygulama paketi + eşleşen kalıntılar) gösterir
- `/Applications/DaVinci Resolve` gibi tek klasörü paylaşan aynı geliştiriciye ait uygulamalar, açıldığında içindeki uygulamaları gösteren tek bir öğe olarak listelenir
- Bir veya daha fazla uygulama seçin; ardından her öğeyi yolu ve boyutuyla listeleyen inceleme ekranını kontrol edin
- Eşleştirme katıdır; böylece bir uygulamayı kaldırmak aynı geliştiricinin diğer uygulamalarıyla paylaşılan dosyalara dokunmaz. Her eşleşme seçili gelir, saklamak istediklerinizin işaretini kaldırabilirsiniz. Üç tür varsayılan olarak işaretsiz gelir: ana klasörünüzde uygulama ayarlarını tutan gizli klasör, içinde betik bulunan Application Scripts klasörü ve başka bir yüklü uygulamanın hâlâ kullandığı dosyalar (bunlar alıkonulur ve hangi uygulamanın kullandığı belirtilir)
- Çalışan bir uygulamadan önce düzgün biçimde çıkması istenir. Kapanmazsa yüklü bırakılır ve seçtiğiniz diğer uygulamaların kaldırılması devam eder
- Onaylanan her şey Purge'ün standart silme motoruyla **Çöp Sepeti'ne** taşınır ve geri alınabilir. Tek istisna Homebrew cask ile kurulan uygulamalardır: inceleme ekranı "Homebrew ile Kaldır" ve "Tümünü Çöp Sepeti'ne Taşı" olmak üzere iki düğme sunar ve Homebrew'in uygulamayı kalıcı olarak sildiğini, ayrıca arka plan servislerini durdurup yardımcı araçları ve yükleyici dosyalarını da kalıcı olarak kaldırabilen kendi kaldırma adımlarını çalıştırdığını belirtir. Birden fazla uygulama kuran cask'ler asla Homebrew'e yönlendirilmez. Kalıntılar yine Çöp Sepeti'ne gider ve Homebrew reddederse uygulama da Çöp Sepeti'ne taşınır
- İsteğe bağlı, varsayılan olarak kapalı: Ayarlar'da **Bir uygulama silindiğinde kalıntıları incele** seçeneğini açın. Küçük bir arka plan izleyicisi — Purge kapalı olsa bile — bir uygulama bu klasörlerden ayrıldığında bunu fark eder, Purge'ü yalnızca o uygulamanın kalıntılarıyla açar ve siz onayladıktan ya da kapattıktan sonra devreden çıkar. İncelemeniz olmadan hiçbir şey taşınmaz. Bu incelemede yalnızca ana klasörünüzdeki tam bundle-id ve app-group eşleşmeleri işaretli gelir; ad tabanlı daha esnek eşleşmeler onaylamanız için işaretsiz gelir
- Bazı uygulamalar yönetici yetkisiyle kurulduğu için hesabınız onları veya `/Library` içindeki kalıntılarını Çöp Sepeti'ne taşıyamaz. Ayarlar'da **Yönetici kilitli uygulamaları parola sormadan kaldır** seçeneğini açtığınızda root olarak çalışan küçük bir yardımcı bunları Çöp Sepeti'nize taşır. Yalnızca kaldırıcının onayladığı yolları ve kalan macOS güncelleme dosyalarını taşır. Standart bir hesapta bu ayar **Yönetici kilitli uygulamaları kaldır** olarak görünür ve Purge her seferinde yönetici adı ve parolası ister
- Finder'dan da başlatabilirsiniz: Ayarlar'da **Finder sağ tık menüsünden kaldır** seçeneğini açın, ardından bir uygulamaya sağ tıklayıp **Purge ile Kaldır** deyin. Bir uygulamayı Purge'ün Dock simgesine sürüklemek de aynı işi yapar

Uygulama Kaldırıcı'da **Yüklü Uygulamalar** yanında tarama bir şey bulduğunda görünen iki liste daha vardır:

- **Kalıntılar**: Artık silinmiş uygulamalardan geriye kalan ve Purge'ün eşleştirme yöntemine göre gruplanmış dosyalar. Sizin yerinize hiçbir şey seçilmez
- **Komut Satırı Araçları**: Betikle kurulan araçlar Çöp Sepeti'ne gider (ana klasörünüzdeki araç klasörü, `~/.local/bin` içindeki başlatma komutları ve arka plan görevleri). Homebrew, npm, pipx, uv veya Cargo ile kurulan araçlar ilgili paket yöneticisinin kendi kaldırma komutuyla kalıcı olarak silinir. Onay ekranı iki grubu ayrı listeler

### Güvenlik etiketleri

Purge tanıdığı her öğeye bir güvenlik etiketi atar:

| Etiket | Anlamı |
|-------|---------|
| ✅ **Temizlemesi Güvenli** | Bilinen önbellek veya yeniden oluşturulabilir artık; güvenle kaldırılabilir |
| ⚠️ **Önce Kontrol Et** | Güvenli olabilir ancak zahmete yol açabilir |

**Tümü**, **Temizlemesi Güvenli** veya **Önce Kontrol Et** (⌥⌘1–⌥⌘3) ile filtreleyin. Boyut, değişiklik tarihi veya ada göre sıralayın.

Tanınmayan klasörler listeye hiç alınmaz. Purge yalnızca ne olduğunu bildiği öğeleri gösterir.

Etiketler ve açıklamalar baştan sona okumak için değil, istediğinizde kontrol etmek içindir. Güvenli öğeleri seçip temizleyebilir veya önce tek bir satırın gerekçesini açıp okuyabilirsiniz.

### Temizleme

- **Seçilenleri Temizle**: Belirli satırları seçin, onay penceresinde inceleyin ve silin. Herhangi bir şey kaldırılmadan önce Git ve kilit dosyası kontrolleri çalışır
- **Güvenli Öğeleri Temizle**: Genel Bakış'ta tek bir onayla tüm "Temizlemesi Güvenli" öğeleri Çöp Sepeti'ne taşır
- **Güvenli Dosyaları Temizle**: Aynı güvenli temizlik menü çubuğundan da yapılabilir
- **Zamanlanmış temizlik**: **Ayarlar → Temizleme** içinde **Otomatik temizle** seçeneğini açın ve sıklığı seçin (haftalık, aylık, 3 ayda bir veya gün/hafta/ay cinsinden **Özel** aralık). Temizlik zamanı geldiğinde Purge yerel bir hatırlatma gönderir ve uygulamayı bir sonraki açışınızda ya da öne getirişinizde temizliği çalıştırır. İlk seferde Çöp Sepeti'ne taşınacak her öğeyi yolu ve boyutuyla listeler ve siz "Çöp Sepeti'ne Taşı" demeden hiçbir şeye dokunmaz. "Şimdi Değil" listeyi kapatır ve bir saat sonra uygulamaya döndüğünüzde yeniden açar. Arka planda asla sessizce temizlik yapmaz
- Dosya ve klasörler **Çöp Sepeti'ne** taşınır; Purge Çöp Sepeti'ni asla boşaltmaz. iOS simülatörleri ve çalışma zamanları `simctl`, Metal Toolchain `xcodebuild -deleteComponent`, yerel Time Machine anlık görüntüleri `tmutil` (en yenisi ve son yedeğinizinki korunarak) ile kalıcı olarak silinir; Apple Intelligence modelleri Apple varlık servisiyle serbest bırakılır ve tekrar indirilebilir; paket yöneticisiyle kaldırılmasını seçtiğiniz araç ve cask uygulamaları kendi paket yöneticisiyle kalıcı olarak kaldırılır

### Ayarlar

Ayarlar, kenar çubuğunda beş gruptan oluşan bir sekmedir (⌘,):

- **Genel**: Yeni kurulumda kapalı gelen **Purge'ü menü çubuğunda tut**. Açıkken pencereyi kapatsanız da Purge çalışmaya devam eder ve **Oturum açıldığında Purge'ü başlat** ile **Dock simgesini gizle** seçeneklerini kullanabilirsiniz. **Görünüm** Otomatik, Açık veya Koyu olabilir
- **Temizleme**: Sıklık ve sonraki temizlik tarihiyle **Otomatik temizle**; Geliştirici Projeleri eşiği için **Projeler şu süreden sonra eski sayılır**; ana klasörünüz dışında taranacak klasör ve diskler için **Taranacak diğer klasörler**; Purge'ün dokunmamasını istediğiniz klasörleri mevcut boyutlarıyla gösteren **Hariç tutulan klasörler**. Uygulama Önbellekleri, Geliştirici Araçları veya Büyük Dosyalar'da bir satıra sağ tıklayıp **Taramalardan hariç tut** diyerek ekleyebilirsiniz. Hariç tutulan bir simülatör çalışma zamanı adı, derleme numarası ve hariç tutulduğu andaki boyutuyla listelenir. Hariç tutma yalnızca Purge'ün baktığı kapsamı daraltır
- **Kaldırma**: **Finder sağ tık menüsünden kaldır**, **Purge uygulamaları nerede arar**, **Bir uygulama silindiğinde kalıntıları incele** ve **Yönetici kilitli uygulamaları parola sormadan kaldır**
- **Güncellemeler ve Geçmiş**: **Güncellemeleri otomatik denetle**, **Güncellemeleri otomatik yükle** ve her otomatik ve manuel temizliği kazanılan alan ve öğe sayısıyla listeleyen **Temizleme geçmişi**. Bir temizliğe tıklayarak Çöp Sepeti'ne taşınanları, kalıcı silinenleri ve atlananları görebilirsiniz
- **Kaldır**: [Kaldırma](#kald%C4%B1rma) bölümünde açıklanan **Purge'ü Kaldır**

### Daha fazlası

- **İlk açılış rehberi**: Karşılama, ilk tarama ve güvenli öğeleri Çöp Sepeti'ne taşıyan düğmeyle sonuçlar. Sonda, Purge'ün izni yoksa isteğe bağlı Tam Disk Erişimi istemi yer alır
- **Menü çubuğu yardımcısı**: Geri kazanılabilir alanı bir bakışta görme, hızlı açma ve tarama/temizleme işlemleri. İsteğe bağlıdır ve yeni kurulumda kapalıdır; Ayarlar'dan **Purge'ü menü çubuğunda tut** seçeneğiyle açabilirsiniz
- **Kestirmeler ve Spotlight**: Üç işlem — Gereksiz Dosyaları Tara, Güvenli Gereksiz Dosyaları Temizle ve Bir Uygulamayı Kaldır
- **Diller**: Uygulama İngilizce, Basitleştirilmiş Çince, Rusça, Türkçe ve Arapça dillerinde çalışır ve sistem dilinizi izler
- **Disk özeti**: Genel Bakış kullanılan ve boş alanı gösterir; kenar çubuğu Çöp Sepeti'ndeki mevcut boyutu ve her tarama sekmesinin boyutunu gösterir
- **Uygulama içi güncellemeler**: Hakkında ekranı yeni sürümleri denetler, indirir ve yükler

### Klavye kısayolları

| Kısayol | İşlem |
|----------|--------|
| ⌘R | Geçerli sekmeyi tara (Genel Bakış'ta Her Şeyi Tara) |
| ⇧⌘R | Herhangi bir sekmeden Her Şeyi Tara |
| ⌘1–⌘5 | Genel Bakış, Uygulama Önbellekleri, Geliştirici Araçları, Büyük Dosyalar veya Uygulama Kaldırıcı'ya git |
| ⌥⌘1–⌥⌘3 | Uygulama Önbellekleri ve Geliştirici Araçları'nda Tümü, Temizlemesi Güvenli veya Önce Kontrol Et filtrelemesi |
| ⌘F | Büyük Dosyalar ve Uygulama Kaldırıcı'da ara |
| ⌘, | Ayarlar'ı aç |

---

## İndir

<div align="center">

<a href="https://github.com/jithin-sabu/purge-app/releases/latest"><img src="https://img.shields.io/badge/download-Purge-2EA043?style=flat&logo=apple&logoColor=white" alt="Purge İndir" /></a>

</div>

---

## Kurulum

Purge'ü kurmanın iki yolu vardır: terminali seviyorsanız Homebrew ile veya uygulamayı doğrudan indirerek. İkisi de aynı yere kurulur.

### Homebrew ile kurulum

```bash
brew install --cask purge
```

Bu komut Purge'ü resmi Homebrew cask paketinden kurar ve Homebrew indirmenin sağlama toplamını (checksum) sizin için otomatik olarak doğrular.

### Elle kurulum

Doğrudan indirme için aşağıdaki adımları izleyin.

#### Adım 1: İndirin

Yukarıdaki indirme bağlantısına tıklayıp `.dmg` dosyasını indirin.

#### Adım 2: İndirmeyi doğrulayın (isteğe bağlı ama önerilir)

> [!TIP]
> Purge dosya sildiği için sağlama toplamını doğrulamak, indirdiğiniz dosyanın yayımlanan sürümle bayt bayt aynı olduğunu ve aktarım sırasında değiştirilmediğini doğrular.

Her sürümde eşleşen bir `.dmg.sha256` sağlama toplamı dosyası bulunur. Hem `.dmg` hem de `.dmg.sha256` dosyasını aynı klasöre indirin, ardından Terminal'de çalıştırın:

```bash
cd ~/Downloads
shasum -a 256 -c Purgev*.dmg.sha256
```

`OK` ile biten bir sonuç, dosyanın yayımlanan sürümle eşleştiğini gösterir.

#### Adım 3: Kurun

`.dmg` dosyasını açın ve Purge'ü Uygulamalar klasörüne sürükleyin.

#### Adım 4: Purge'ü açın

Purge'ü açmak için çift tıklayın. Purge Apple tarafından noter tasdiklidir (notarized), bu yüzden ek bir adım olmadan normal şekilde açılır.

#### Adım 5: Purge'ün daha derine bakmasına izin verin (isteğe bağlı)

Purge, Tam Disk Erişimi olmadan da çalışır: Uygulama Önbellekleri ve Geliştirici Araçları'nı tarar. Bu izinle birlikte App Store uygulamalarının önbelleklerini, büyük dosyaları, yüklü uygulamaları ve silinmiş uygulamaların kalıntılarını da bulur.

1. İlk çalıştırmanın sonunda veya daha sonra **Daha derine bak** üzerinden **Purge'e izin ver** düğmesine tıklayın. Sistem Ayarları açılır
2. Listede Purge'ü bulun ve anahtarını açın
3. Purge'e dönün; değişikliği kendisi algılar. macOS uygulamayı yeniden açmayı önerirse onaylayın

Atlamak için **Şimdi değil** seçin. Erişimi istediğiniz zaman Sistem Ayarları'ndan kapatabilirsiniz.

---

## Güncelleme

Purge kendini yerinde günceller. Günde bir kez yeni sürüm kontrolü yapar ve yeni sürüm varsa sürüm notlarıyla birlikte güncelleme penceresi açılır. **Güncellemeyi Yükle** dediğinizde Purge sürümü indirir, imzasını doğrular, yükler ve yeniden başlar. Sürüm sayfasına gitmeniz veya bir şey sürüklemeniz gerekmez.

Varsayılan olarak onayınız olmadan hiçbir şey yüklenmez. İstediğiniz zaman **Hakkında** ekranından da kontrol edebilirsiniz; Purge'ün kendiliğinden kontrol etmesini istemiyorsanız **Ayarlar → Güncellemeler ve Geçmiş** altında **Güncellemeleri otomatik denetle** seçeneğini kapatın.

Soru sorulmasını istemiyorsanız aynı yerden **Güncellemeleri otomatik yükle** seçeneğini açın veya güncelleme penceresindeki kutucuğu işaretleyin. Yeni sürümler arka planda indirilir ve Purge'den bir sonraki çıkışınızda yüklenir. Bir güncelleme hazır olduğunda Purge menüsündeki, menü çubuğundaki veya **Hakkında** ekranındaki **Güncellemek İçin Yeniden Başlat** seçeneği anında kurar. Bu, Purge'ü menü çubuğunda tutup nadiren kapatıyorsanız oldukça kullanışlıdır.

Güncellemeler, App Store dışındaki Mac uygulamalarının standart güncelleme çatısı olan [Sparkle](https://sparkle-project.org) ile sunulur. Her güncelleme yalnızca geliştiricinin makinesinde bulunan bir anahtarla imzalanır ve Purge eşleşen imzaya sahip olmayan hiçbir indirmeyi kabul etmez.

### Homebrew ile güncelleme

Homebrew üzerinden kurduysanız terminalden güncelleyebilirsiniz:

```bash
brew upgrade --cask purge
```

İki yöntem de sorunsuzdur. Ayarlarınız, temizlik zamanlamanız ve geçmişiniz uygulamadan ayrı tutulduğu için nasıl güncellerseniz güncelleyin korunur. Tam Disk Erişimi iznini de yeniden vermeniz gerekmez.

Geçmiş sürümlere dilediğiniz zaman [sürümler sayfasından](https://github.com/jithin-sabu/purge-app/releases) göz atabilirsiniz.

---

## Kaldırma

Purge menüsünden **Purge'ü Kaldır…** veya **Ayarlar → Kaldır → Kaldır…** seçeneğini kullanın. Purge, Mac'inizde arka planda çalıştırdığı bileşenleri (silinen uygulama izleyicisi, yönetici yardımcısı, Finder sağ tık öğesi, temizlik hatırlatıcısı ve oturum açılışında başlatma) listeler, her birini kapatıp gerçekten durduğunu doğrular, ardından kendini Çöp Sepeti'ne taşıyıp çıkar.

Ayarlarınız ve temizleme geçmişiniz Mac'inizde kalır; böylece yeniden kurduğunuzda kaldığınız yerden devam edersiniz. Bunları da kaldırmak için **Ayarları ve geçmişi de Çöp Sepeti'ne taşı** kutucuğunu işaretleyin. Hiçbir şey kalıcı olarak silinmez; hazır olduğunuzda Çöp Sepeti'ni kendiniz boşaltırsınız.

macOS, bir uygulamanın kendi Tam Disk Erişimi iznini kaldırmasına izin vermez. Purge'de bu izin varsa son ekranda **Çık ve Tam Disk Erişimi'ni Aç** seçeneği sunulur. Sistem Ayarları'nda Purge'ü seçip eksi düğmesine tıklayın.

Purge'ü zaten Çöp Sepeti'ne sürüklediniz mi? Arka planda çalışan bir şey kalmaması için tekrar indirip açın ve **Purge'ü Kaldır…** seçeneğini kullanın. Geride hiçbir şey kalmadığını doğrulamak için Purge, **Sistem Ayarları → Genel → Giriş Öğeleri ve Genişletmeler** listesinden kalkmış olmalı ve şu komut hiçbir çıktı vermemelidir:

```bash
pgrep -fl io.getpurge
```

---

## Kaynak koddan derleme

Hazır sürümü indirmek yerine Purge'ü kendiniz derlemek isterseniz şu adımları izleyebilirsiniz.

### Gereksinimler

- macOS 13.0 veya üzeri
- **Xcode 26 veya üzeri** (Mac App Store'dan). Proje Swift 6.2 derleme ayarlarını (varsayılan aktör izolasyonu ve erişilebilir eşzamanlılık) ve `@concurrent` kullandığı için Xcode 26 gerekir; daha eski sürümlerle derlenmez
- [Node.js](https://nodejs.org) 18+ ve npm (yalnızca marka simgelerini yeniden oluşturmak isterseniz gerekir)

Bağımlılıklar ilk derlemede Swift Package Manager tarafından çözülür. Tek bağımlılık, uygulama içi güncellemeleri yöneten [Sparkle](https://github.com/sparkle-project/Sparkle) paketidir.

### Adım 1: Depoyu klonlayın

```bash
git clone https://github.com/jithin-sabu/purge-app.git
cd purge-app
```

### Adım 2: Derleyin ve çalıştırın

Projeyi Xcode ile açın:

```bash
open purge.xcodeproj
```

Ardından **purge** şemasını seçip **⌘R** tuşuna basın.

Proje geliştiricinin Developer ID sertifikasıyla imzalanacak şekilde ayarlıdır. Xcode'da her hedef için **Signing & Capabilities** bölümünü açıp kendi ekibinizi veya **Sign to Run Locally** seçeneğini belirleyin.

Alternatif olarak imzalamayı kapatıp doğrudan komut satırından derleyebilirsiniz:

```bash
# Debug uygulaması derle
xcodebuild -project purge.xcodeproj -scheme purge -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Release uygulaması derle
xcodebuild -project purge.xcodeproj -scheme purge -configuration Release build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Derlenen `Purge.app`, Xcode'un DerivedData klasörüne yazılır (derleme çıktısının sonunda yolu görünür). macOS, sizin imzanızı taşımayan her derlemeyi yeni bir uygulama olarak gördüğü için yeniden derleme sonrasında Tam Disk Erişimi'nin tekrar verilmesi gerekir.

### İsteğe bağlı: marka simgelerini yeniden oluşturma

Uygulama önbelleği simgeleri [simple-icons](https://simpleicons.org) kullanılarak oluşturulur. Yeniden oluşturmak için:

```bash
npm install
npm run generate:icons
```

### Testleri çalıştırma

```bash
xcodebuild test -project purge.xcodeproj -scheme purge -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

İmzalama bayrakları önemlidir: makinede geliştirme sertifikası yoksa test derlemesi tek bir test bile çalışmadan hata verir. Sürekli entegrasyon (CI) da aynı şekilde derler.

---

## Sistem Gereksinimleri

- macOS 13.0 veya üzeri
- Tam Disk Erişimi (isteğe bağlı; Büyük Dosyalar, Uygulama Kaldırıcı ve kalıntılar için gerekir)
- Xcode (isteğe bağlı; iOS simülatörleri ve çalışma zamanları için). Xcode'u sildiyseniz bile Purge geride kalan simülatörleri bulur

---

## Gizlilik

Purge tamamen Mac'inizde çalışır. Hariç tutulan klasörleriniz, temizleme geçmişiniz ve son tarama bilgisi Application Support klasöründe, ayarlarınız ise tercihlerinizde saklanır. Hiçbir veri dışarı yüklenmez. Son tarama, Purge yeniden tarama yaparken gösterecek bir şey olması için kaydedilir. Masaüstü, Belgeler, İndirilenler veya iCloud'dan hiçbir veri buraya yazılmaz; Büyük Dosyalar yalnızca dosya türüne göre toplamları tutar, asla dosya adı kaydetmez.

Purge'ün ağa bağlandığı tek an güncelleme denetimidir. Günde bir kez bu depodaki dosyayı ileten küçük bir sunucu olan updates.purgemac.com adresinden küçük bir XML dosyası (appcast) çeker. Bu sunucu denetim ve indirmeleri yalnızca Purge sürümüne göre günlük toplam olarak sayar; IP adresi veya sizi tanımlayacak hiçbir veri saklamaz. Güncelleme dosyaları yine GitHub Releases üzerinden indirilir. Sunucu kapalıysa bir sonraki denetim dosyayı doğrudan GitHub'dan alır. Denetim, Purge sürümü dışında siz veya Mac'iniz hakkında hiçbir bilgi göndermez ve **Ayarlar → Güncellemeler ve Geçmiş** bölümünden kapatılabilir.

Purge bazı dosya içeriklerini yalnızca Mac'inizde okur. Yinelenenleri bulmak için aynı boyuttaki dosyaları bayt bayt karşılaştırır. Bir dosyanın hangi uygulamaya veya araca ait olduğunu anlamak için uygulamanın `Info.plist`, LaunchAgent plist dosyaları ve komut satırı araçlarını başlatan betikler gibi küçük dosyaları okur. Dosya içeriklerini asla hiçbir yere göndermez.

Purge yapay zeka kullanmaz. Taradığınız veya temizlediğiniz hiçbir şey bir yapay zeka servisine gönderilmez.

---

## Güvenlik

Purge dosya sildiği için güvenlik temel önceliktir. Bilmeniz gereken birkaç nokta:

- **Varsayılan olarak Çöp Sepeti**: Dosya ve klasörler macOS Çöp Sepeti'ne taşınır ve Purge Çöp Sepeti'ni asla boşaltmaz. Kendiniz boşaltana kadar geri alabilirsiniz. iOS simülatörleri ve çalışma zamanları `simctl` ile kalıcı olarak silinir. Xcode Metal Toolchain `xcodebuild -deleteComponent` ile kalıcı olarak silinir ve bir proje gerektirdiğinde yeniden indirilir. Yerel Time Machine anlık görüntüleri `tmutil` ile kalıcı olarak silinir; Purge en yenisini ve son yedeğinizden kalanı korur. Apple Intelligence modelleri Apple'ın varlık servisi üzerinden serbest bırakılır ve Purge'den yeniden indirilebilir. Paket yöneticisi üzerinden kaldırmayı seçtiğiniz komut satırı araçları ve Homebrew cask uygulamaları ilgili yönetici tarafından kalıcı olarak silinir. Docker Desktop veri klasörü Çöp Sepeti'ne taşınır; Purge `docker system prune` çalıştırmaz.
- **İzin listesi tabanlı silme**: Yalnızca açık bir güvenlik izin listesiyle eşleşen yollar temizlenebilir. Purge'ün tanımadığı hiçbir şeye asla dokunulmaz. Uygulamanın kaynak kodundan üretilen [güvenlik sayfası](https://purgemac.com/safety/), izin verilen tüm konumları ve temizliğin asla dokunmayacağı her şeyi listeler.
- **Neyin silineceğine siz karar verirsiniz**: Purge geri kazanılabilir alanı gösterir, neyi temizleyeceğinize siz karar verirsiniz.
- **Root yardımcısı varsayılan olarak kapalı**: Yönetici tarafından kurulmuş uygulamaları taşıyabilmek için Purge, root olarak çalışan küçük bir yardımcı kurabilir. Siz **Yönetici kilitli uygulamaları parola sormadan kaldır** seçeneğini açıp Sistem Ayarları'nda onaylayana kadar kapalı kalır. Tek bir iş yapar: kaldırıcının onayladığı bir yolu veya kalan macOS güncelleme dosyasını Çöp Sepeti'nize taşır. Kaynak kodu `PurgeHelper/` içindedir.
- **Açık kaynak**: İzin listesi dahil tüm silme mantığı bu depodadır; okuyabilir veya kendiniz kaynak koddan derleyebilirsiniz.
- **Apple noter tasdikli**: Uygulama imzalanmış ve noter tasdikinden geçirilmiştir; böylece macOS yayımlandıktan sonra değiştirilmediğini doğrulayabilir.
- **İmzalı güncellemeler**: Uygulama içi güncellemeler kurulmadan önce imza anahtarına karşı doğrulanır. O anahtarla imzalanmamış hiçbir güncelleme kabul edilmez.

Bir güvenlik açığı veya silinmemesi gerekirken silinebilecek bir yol mu buldunuz? Lütfen bildirin; ayrıntılar için [SECURITY.md](SECURITY.md) dosyasına bakın.

---

## Katkıda Bulunma

Hata raporları, güvenlik bulguları ve pull request'ler memnuniyetle karşılanır. [CONTRIBUTING.md](CONTRIBUTING.md) projenin nasıl kurulacağını ve bir değişikliğin nasıl kolayca incelenebileceğini anlatır. Güvenlik izin listesine, asla silinmeyecek korumalara veya tarama mantığına dokunan değişiklikler kasıtlı olarak daha kapsamlı incelenir ve daha uzun sürebilir.

Güvenlik sorunları bunun istisnasıdır: herkese açık bir issue açmak yerine [SECURITY.md](SECURITY.md) üzerinden gizli olarak bildirin.

---

## Lisans

Purge [MIT Lisansı](LICENSE) altında yayımlanır. Kullanmakta, okumakta, değiştirmekte ve dağıtmakta özgürsünüz.

---

## Destek

Purge ücretsizdir. Diskinizde yer açmanıza yardımcı olduysa, uygulamanın **Hakkında** ekranından veya doğrudan [Buy Me a Coffee](https://buymeacoffee.com/jithinsabu) üzerinden işletme giderlerine katkıda bulunabilirsiniz.

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
