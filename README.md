# LidarCAD

iPhone'un LiDAR tarayıcısıyla bir mekânı, bir bölgeyi ya da bir nesneyi tarayıp
sonucu **Fusion 360'a sokulabilir** dosyalara çeviren iOS uygulaması.

*LidarCAD turns iPhone LiDAR scans of rooms, regions and objects into CAD-ready
OBJ, STL, PLY and DXF files for Fusion 360. Turkish UI; the code comments are
in Turkish too.*

Fark yaratan kısım dışa aktarma tarafı: ham ARKit mesh'ini Fusion'a atmak işe
yaramaz, çok yoğun, eğri ve yanlış birimde gelir. LidarCAD taramayı sadeleştirir,
duvarları eksenlere oturtur, zemini Z=0'a taşır, milimetreye çevirir ve istenen
yükseklikten **DXF kesit** çıkarır. Kesit Fusion'da doğrudan skeç olarak açılır.

## Üç tarama kipi

| Kip | Ne için | Nasıl çalışır | Varsayılan çıktı |
|---|---|---|---|
| **Mekân** | Oda, koridor, mağara, cephe | ARKit sahne rekonstrüksiyonu, hacmin tamamı | Orta sadeleştirme, duvar hizalama, 1,2 m plan kesiti, OBJ + STL + DXF |
| **Bölge** | Yuva, girinti, montaj yüzeyi | Kutu yerleştirilir, kutunun dışında kalan her şey atılır | İnce sadeleştirme, duvar hizalama kapalı, 5 mm nokta bulutu, OBJ + STL + DXF + PLY |
| **Nesne** | Serbest duran tekil parça | Apple Object Capture ile fotogrametri; etrafında tur atılır, model cihazda oluşur | İnce sadeleştirme, OBJ + STL |

Üç kip aynı dışa aktarma hattını paylaşır; yalnızca varsayılanları farklıdır.
Bir odada duvar hizalama ve plan kesiti anlamlıdır, torpidodaki bir teyp
yuvasında değildir.

## Gereksinimler

- LiDAR'lı iPhone ya da iPad (Pro modeller). iPhone 16 Pro ile geliştirildi.
  Simülatörde LiDAR yoktur, gerçek cihaz gerekir.
- iOS 17 ve üstü. Nesne kipi Apple Object Capture'ı kullanır, o da iOS 17 ister.
- Derlemek için Mac'te Xcode. Proje Xcode 27 ile derlenmiştir; ücretsiz Apple ID
  yeterlidir.

## Kurulum ve çalıştırma

1. `LidarCAD.xcodeproj` dosyasını Xcode'da açın.
2. Sol panelde **LidarCAD** hedefi, **Signing & Capabilities** sekmesi:
   **Team** olarak kendi Apple ID'nizi seçin ve **Bundle Identifier**'ı
   `com.<adiniz>.LidarCAD` gibi benzersiz bir değerle değiştirin.
3. iPhone'u kabloyla bağlayın, üstteki hedef listesinden seçin, ⌘R.
4. İlk çalıştırmada telefonda **Ayarlar → Genel → VPN ve Cihaz Yönetimi**
   altından geliştirici sertifikanıza güvenin.

> Ücretsiz Apple ID ile imzalanan uygulama 7 gün sonra açılmaz; yeniden ⌘R
> yapmak yeter. Ücretli Apple Developer hesabıyla imza bir yıl geçerlidir.

`project.yml` yedek plandır: `.xcodeproj` bozulursa `brew install xcodegen && xcodegen`
ile yeniden üretilir.

## Kullanım

**Mekân:** Tarama açılışta başlar, mesh canlı olarak görüntünün üstüne çizilir.
Telefonu yüzeyden 0,5 ile 5 m arasında tutun, yavaş hareket edin. Tur atıp
başladığınız noktaya geri dönün; bu, biriken kaymayı ciddi ölçüde kapatır.
**Bitir** ile dışa aktarma ekranına geçilir.

**Bölge:** Hedefi kadraja alıp **Kutuyu yerleştir** deyin; kutu 45 cm önünüze
düşer. Kaydırıcıyla boyutu 10 ile 150 cm arasında ayarlayın, hedefi biraz taşacak
kadar. Yavaşça tarayın; koltuk, direksiyon, cam gibi kutu dışındaki her şey atılır.
Kesit eklediğinizde uygulama modelin orta yüksekliğini önerir.

**Nesne:** Kılavuzlu akış: nesneyi algıla, kutuyu onayla, etrafında tur at,
istenirse nesneyi ters çevirip alt yüzey için ikinci tur, bitir. Model cihazda
oluşturulur ve birkaç dakika sürer. Nesnenin dokusu olmalı ve ortam iyi
aydınlatılmış olmalı; parlak metal, cam ve düz beyaz yüzeyler çıkmaz. Bunlara
mat sprey ya da pudra atmak standart çözümdür.

## Dışa aktarma seçenekleri

| Ayar | Seçenekler | Fusion 360 için |
|---|---|---|
| Birim | m, cm, mm | **mm** |
| Yukarı eksen | Y yukarı, Z yukarı | **Z yukarı** |
| Sadeleştirme | Ham, İnce 1,2 cm, Orta 3 cm, Kaba 6 cm | Convert Mesh için **Kaba** |
| Duvarları eksenlere oturt | açık / kapalı | Mekânda **açık** |
| Zemini Z=0'a taşı | açık / kapalı | **Açık** |
| Kesit yükseklikleri | istenen sayıda, her biri ayrı DXF | Kapı ve pencere için 1,0 ile 1,2 m |
| Format | OBJ, STL, PLY mesh, PLY nokta bulutu, DXF | **DXF + OBJ** |

İşlem sırası sabittir: yüzey sınıfı filtresi → sadeleştirme → eksen çevrimi →
duvar hizalama → zemine oturtma → birim ölçekleme. Seçenekler değiştikçe
ekranda kaç üçgen çıkacağı gösterilir; Fusion'ın Convert Mesh sınırına
takılmamak için dışa aktarmadan önce bilmek gerekir.

### Neden DXF?

Gürültülü bir tarama mesh'ini katı modele çevirmeye çalışmak genelde hüsranla
biter. Profesyonel iş akışı taramayı **referans** olarak kullanmaktır:

1. Fusion'da `Insert → Insert DXF`, bir düzlem seçin.
2. Kesit skeç olarak gelir.
3. Üstünden ölçülendirilmiş, temiz geometri çizin.

### Diğer formatlar

- **OBJ / STL:** `Insert → Insert Mesh`. Unit Type'ı dışa aktarma birimiyle aynı
  seçin. STL birimsizdir, daima mm olarak okunur.
- **PLY (mesh):** MeshLab'de delik kapatma, Poisson rekonstrüksiyonu.
- **PLY (nokta bulutu):** CloudCompare, Rhino. Mesh'ten daha keskindir; ölçü
  almak ve kendi kesitlerinizi çıkarmak için. Bölge kipinde 5 mm, diğerlerinde
  1 cm voxel.

## Dosyaları Mac'e alma

Dışa aktarma ekranındaki **Paylaş / AirDrop**, ya da Dosyalar uygulaması →
*Benim iPhone'umda* → *LidarCAD* → *Scans*; Mac'te Finder → iPhone → Dosyalar.
Her taramanın klasöründe `OKUBENI.txt` vardır: ölçüler, uygulanan dönüş açısı
ve Fusion'a alma adımları.

## Doğruluk hakkında

iPhone LiDAR'ı oda ölçeğinde tipik olarak **1 ile 2 cm** sapar, uzun
koridorlarda kayma birikir. Fotogrametri daha iyidir ama garanti değildir.
Tarama size **şekli ve bağlamı** verir, ölçüyü değil.

- Oturacak bir parça çiziyorsanız kritik ölçüleri (yuva genişliği, vida
  aralığı, derinlik) kumpasla alın ve Fusion'da düzeltin; ince bir test
  baskısıyla deneyin.
- Taramada bilinen bir ölçü bırakın (kapı genişliği, bir metre); Fusion'da
  `Inspect → Measure` ile doğrulayın, sapma varsa `Scale` uygulayın.
- Cam, ayna ve parlak siyah yüzeyler taranmaz; o bölgeleri elle çizin.
- Güneş altında LiDAR bozulur.

## Proje yapısı

```
LidarCAD/
├── Core/              ARKit'e bağımsız; macOS'ta derlenip test edilir
│   ├── Geometry.swift          mesh tipleri, birim ve eksen dönüşümü
│   ├── Decimator.swift         vertex-clustering sadeleştirme, O(n)
│   ├── WallAligner.swift       baskın duvar yönüne "Manhattan" hizalama
│   ├── SectionSlicer.swift     düzlem-mesh kesişimi, yatay ve dikey kesit
│   ├── CropBox.swift           bölge kipinin kırpma kutusu
│   ├── PointCloud.swift        voxel-hash nokta bulutu biriktirici
│   ├── ScanKind.swift          üç kip ve varsayılanları
│   ├── ExportPipeline.swift    seçenekler ve dönüşüm sırası
│   └── Writers/                OBJ, STL, PLY, DXF
├── Scanning/          ARKit ve RealityKit katmanı
│   ├── ScanSession.swift             oturum, anchor toplama, derinlik kareleri
│   ├── ARMeshExtraction.swift        ARMeshAnchor → MeshData
│   ├── DepthUnprojector.swift        derinlik haritası → renkli noktalar
│   ├── ObjectCaptureController.swift Object Capture sarmalayıcısı
│   └── RealityMeshExtractor.swift    Object Capture modelinden mesh
├── Export/            dosya yazımı ve OKUBENI.txt
└── UI/                SwiftUI: kip seçimi, tarama, nesne akışı, dışa aktarma
Tests/                 macOS doğrulama koşucusu
```

## Testler

`Core` ve `Export` katmanları ARKit'e dokunmaz; Xcode'suz, doğrudan macOS'ta
koşar:

```bash
./Tests/run.sh
```

98 kontrol: birim dönüşümü, eksen çevriminin sağ el sistemini koruması,
sadeleştirmede dejenere üçgen kalmaması, duvar hizalamanın eğik odayı düzeltmesi,
kırpma kutusu, kesit çevresinin doğru çıkması, OBJ/STL/PLY/DXF'in bayt düzeyinde
format uyumu.

## Lisans

Bu proje [PolyForm Noncommercial 1.0.0](LICENSE) ile lisanslıdır: kaynak kodu
görülebilir, kişisel ve ticari olmayan amaçlarla kullanılıp değiştirilebilir;
ticari kullanım için yazarla iletişime geçin. Uygulama yalnızca Apple'ın
ARKit, RealityKit ve Object Capture çerçevelerini kullanır, üçüncü taraf
bağımlılığı yoktur.
