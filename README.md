# LidarCAD

iPhone 16 Pro'nun LiDAR tarayıcısıyla mekân tarayıp sonucu **Fusion 360'a
sokulabilir** dosyalara çeviren iOS uygulaması.

Fark yaratan kısım export tarafı: ham ARKit mesh'i Fusion'a atmak işe
yaramaz — çok yoğun, eğri ve yanlış birimde gelir. Bu uygulama taramayı
sadeleştirir, duvarları eksenlere oturtur, zemini Z=0'a taşır, mm'ye
çevirir ve istenen yükseklikten **DXF kesit** çıkarır.

---

## Önce: Xcode kurulumu

Bu Mac'te şu an sadece Command Line Tools var, tam Xcode yok. Projeyi
derleyebilmek için Xcode şart:

1. App Store > Xcode > Yükle (~10–15 GB, kurulum uzun sürer)
2. Kurulum bitince bir kere açıp lisansı kabul edin
3. Terminalde:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Cihazda çalıştırma

LiDAR simülatörde yok — gerçek iPhone'da çalıştırmanız gerekiyor.

1. `LidarCAD.xcodeproj`'u Xcode'da açın
2. Sol panelde **LidarCAD** hedefini seçin > **Signing & Capabilities**
   - **Team**: kendi Apple ID'nizi seçin (ücretsiz hesap yeterli)
   - **Bundle Identifier**: `com.example.LidarCAD` benzersiz değil,
     `com.<adiniz>.LidarCAD` gibi bir şeyle değiştirin
3. iPhone'u kabloyla bağlayın, üstteki hedef listesinden seçin
4. ⌘R
5. İlk çalıştırmada telefonda: **Ayarlar > Genel > VPN ve Cihaz Yönetimi**
   > geliştirici sertifikanıza güvenin

> Ücretsiz Apple ID ile imzalanan uygulamalar 7 gün sonra açılmaz;
> tekrar ⌘R yapmanız yeterli. Ücretli Developer hesabıyla 1 yıl.

## Kullanım

1. Uygulama açılır açılmaz tarama başlar. Mesh canlı olarak üstüne çizilir.
2. Telefonu yüzeyden **0,5–5 m** mesafede tutun, **yavaş** hareket edin.
3. Tur atıp **başladığınız noktaya geri dönün** — bu, birikmiş drift'i
   ciddi oranda kapatır.
4. **Bitir** > export ekranı.

## Export seçenekleri

| Ayar | Fusion 360 için |
|---|---|
| Birim | **mm** |
| Yukarı eksen | **Z yukarı** |
| Sadeleştirme | **Kaba (6 cm)** — Convert Mesh kullanacaksanız |
| Duvarları eksenlere oturt | **Açık** |
| Zemini Z=0'a taşı | **Açık** |
| Format | **DXF** + **OBJ** |

### Neden DXF?

Gürültülü bir tarama mesh'ini katı modele çevirmeye çalışmak genelde
hüsranla biter. Profesyonel iş akışı taramayı **referans** olarak
kullanmaktır:

1. Fusion'da `Insert > Insert DXF`, bir düzlem seçin
2. Kesit skeç olarak gelir
3. Üstünden ölçülendirilmiş, temiz geometri çizin

Kesit yüksekliğini export ekranından ayarlayabilir, birden fazla
yükseklik ekleyebilirsiniz (her biri ayrı dosya olur). Kapı/pencere
görmek için 1,0–1,2 m tipiktir.

### Diğer formatlar

- **OBJ / STL** — `Insert > Insert Mesh`. Unit Type'ı export birimiyle
  aynı seçin. STL birimsizdir, daima mm olarak okunur.
- **PLY (mesh)** — MeshLab'de delik kapatma, Poisson reconstruction.
- **PLY (nokta bulutu)** — CloudCompare, Rhino. Mesh'ten daha keskin;
  ölçü almak ve kendi kesitlerinizi çıkarmak için.

## Dosyaları Mac'e alma

- Export ekranındaki **Paylaş / AirDrop**, veya
- Dosyalar uygulaması > *Benim iPhone'umda* > *LidarCAD* > *Scans*,
  ya da Mac'te Finder > iPhone > Dosyalar sekmesi

Her taramanın klasöründe `OKUBENI.txt` var: ölçüler, uygulanan dönüş
açısı ve Fusion'a alma adımları yazılı.

## Doğruluk hakkında

iPhone LiDAR'ı oda ölçeğinde tipik olarak **1–2 cm** sapma yapar ve
uzun koridorlarda drift birikir. Teknik CAD işinde:

- Taramada bilinen bir ölçü bırakın (kapı genişliği, bir metre)
- Fusion'da `Inspect > Measure` ile doğrulayın
- Sapma varsa modele `Scale` uygulayın
- Cam, ayna ve parlak siyah yüzeyler taranmaz — o bölgeleri elle çizin
- Dışarıda güneş altında LiDAR bozulur

## Proje yapısı

```
LidarCAD/
├── Core/              ARKit'e bağımsız — macOS'ta test edilebilir
│   ├── Geometry.swift         mesh tipleri, birim/eksen dönüşümü
│   ├── Decimator.swift        vertex-clustering sadeleştirme
│   ├── WallAligner.swift      baskın duvar yönüne hizalama
│   ├── SectionSlicer.swift    düzlem-mesh kesişimi
│   ├── PointCloud.swift       voxel-hash biriktirici
│   ├── ExportPipeline.swift   seçenekler + dönüşüm sırası
│   └── Writers/               OBJ, STL, PLY, DXF
├── Scanning/          ARKit katmanı
│   ├── ScanSession.swift      oturum, anchor toplama, istatistik
│   ├── ARMeshExtraction.swift ARMeshAnchor -> MeshData
│   └── DepthUnprojector.swift derinlik haritası -> renkli noktalar
├── Export/
└── UI/
```

## Testler

`Core` ve `Export` katmanları ARKit'e dokunmaz, bu yüzden Xcode olmadan
doğrudan macOS'ta koşturulabiliyor:

```bash
./Tests/run.sh
```

85 kontrol: birim dönüşümü, eksen çevriminin sağ el sistemini koruması,
sadeleştirmede dejenere üçgen kalmaması, duvar hizalamanın eğik odayı
düzeltmesi, kesit çevresinin doğru çıkması, OBJ/STL/PLY/DXF'in byte
düzeyinde format uyumu.
