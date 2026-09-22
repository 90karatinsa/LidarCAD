import Foundation

/// Üç tarama kipi aynı export hattını paylaşır ama varsayılanları farklıdır:
/// mekânda duvar hizalama ve 1,2 m plan kesiti anlamlıdır, torpidodaki bir
/// teyp yuvasında değil.
enum ScanKind: String, Codable, CaseIterable, Identifiable {
    /// ARKit sahne rekonstrüksiyonu — oda, koridor, mağara, cephe.
    case space
    /// Kutuyla sınırlanmış LiDAR taraması — yuva, girinti, montaj yüzeyi.
    case region
    /// Apple Object Capture (fotogrametri) — serbest duran tekil nesne.
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .space:  return "Mekân"
        case .region: return "Bölge"
        case .object: return "Nesne"
        }
    }

    var subtitle: String {
        switch self {
        case .space:
            return "Oda, koridor, mağara, cephe. Hacmin tamamını çıkarır."
        case .region:
            return "Bir yuva veya montaj yüzeyi. Kutuyla sınırlarsınız, sadece orası kalır."
        case .object:
            return "Serbest duran parça. Etrafında tur atılır, fotoğraflardan model çıkar."
        }
    }

    var systemImage: String {
        switch self {
        case .space:  return "cube.transparent"
        case .region: return "viewfinder.rectangular"
        case .object: return "rotate.3d"
        }
    }

    /// Nokta bulutu voxel boyu, metre. Küçük bölgede daha sık örnekleme
    /// anlamlı; bütün odada bellek yakar.
    var cloudVoxelSize: Float {
        switch self {
        case .space:  return 0.01
        case .region: return 0.005
        case .object: return 0.01
        }
    }

    var defaultOptions: ExportOptions {
        var options = ExportOptions()
        options.unit = .millimeters
        options.upAxis = .zUp

        switch self {
        case .space:
            options.detail = .medium
            options.alignToWalls = true
            options.recenterToFloor = true
            options.sectionHeights = [1.2]
            options.formats = [.obj, .stl, .dxf]

        case .region:
            // Yuvanın kenarları önemli; agresif sadeleştirme onları yuvarlatır.
            options.detail = .fine
            // Girintinin "duvarı" yok, baskın yön araması yanıltıcı olur.
            options.alignToWalls = false
            options.recenterToFloor = true
            // Yükseklik bölgenin boyuna bağlı; kullanıcı eklediğinde
            // model yüksekliğinin yarısını öneriyoruz.
            options.sectionHeights = []
            // Nokta bulutu burada mesh'ten hassas — ölçü almak için şart.
            options.formats = [.obj, .stl, .dxf, .plyCloud]

        case .object:
            options.detail = .fine
            options.alignToWalls = false
            options.recenterToFloor = true
            options.sectionHeights = []
            options.formats = [.obj, .stl]
        }
        return options
    }
}
