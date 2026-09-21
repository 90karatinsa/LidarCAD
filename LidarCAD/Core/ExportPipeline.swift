import Foundation
import simd

enum DetailLevel: String, CaseIterable, Identifiable, Codable {
    case raw
    case fine
    case medium
    case coarse

    var id: String { rawValue }

    /// Vertex-clustering hücre boyu, metre. 0 = sadeleştirme yok.
    var cellSize: Float {
        switch self {
        case .raw:    return 0
        case .fine:   return 0.012
        case .medium: return 0.03
        case .coarse: return 0.06
        }
    }

    var label: String {
        switch self {
        case .raw:    return "Ham"
        case .fine:   return "İnce (1,2 cm)"
        case .medium: return "Orta (3 cm)"
        case .coarse: return "Kaba (6 cm)"
        }
    }

    var hint: String {
        switch self {
        case .raw:    return "Hiçbir şey kaybetme. Çok ağır, Fusion zorlanır."
        case .fine:   return "Görsel referans, Blender/MeshLab için."
        case .medium: return "Dengeli. Çoğu iş için bunu kullanın."
        case .coarse: return "Fusion 360 Convert Mesh için en uygun yoğunluk."
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case obj
    case stl
    case plyMesh
    case plyCloud
    case dxf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .obj:      return "OBJ (mesh)"
        case .stl:      return "STL (mesh, binary)"
        case .plyMesh:  return "PLY (mesh)"
        case .plyCloud: return "PLY (nokta bulutu)"
        case .dxf:      return "DXF (kesit)"
        }
    }

    var hint: String {
        switch self {
        case .obj:      return "Fusion 360 Insert Mesh, Blender, MeshLab."
        case .stl:      return "Fusion 360, 3B baskı. Birimsiz — mm seçin."
        case .plyMesh:  return "MeshLab onarım / Poisson için."
        case .plyCloud: return "CloudCompare, Rhino. Ham LiDAR hassasiyeti."
        case .dxf:      return "Fusion 360 Insert DXF — skeç olarak açılır."
        }
    }

    var fileExtension: String {
        switch self {
        case .obj:      return "obj"
        case .stl:      return "stl"
        case .plyMesh:  return "ply"
        case .plyCloud: return "ply"
        case .dxf:      return "dxf"
        }
    }
}

struct ExportOptions: Codable, Equatable {
    var unit: LengthUnit = .millimeters
    var upAxis: UpAxis = .zUp
    var detail: DetailLevel = .medium
    var classes: Set<UInt8> = Set(SurfaceClass.allCases.map(\.rawValue))
    /// Modeli XY'de ortalar ve en alçak noktasını Z=0'a oturtur.
    var recenterToFloor: Bool = true
    /// Baskın duvar yönünü X/Y eksenlerine oturtur.
    var alignToWalls: Bool = true
    /// Zeminden yükseklik, metre. Her biri ayrı bir DXF dosyası olur.
    var sectionHeights: [Float] = [1.2]
    var formats: Set<ExportFormat> = [.obj, .stl, .dxf]
}

struct PreparedScan {
    var mesh: MeshData
    var cloud: CloudSnapshot
    var unit: LengthUnit
    /// Hedef birime çevrilmiş kesit yükseklikleri.
    var sectionHeights: [Float]
    /// Duvar hizalaması için uygulanan dönüş (derece); uygulanmadıysa nil.
    var appliedYawDegrees: Float?
}

enum MeshPipeline {

    /// Sıra önemli: sınıf filtresi -> sadeleştirme -> eksen çevrimi ->
    /// duvar hizalama -> zemine oturtma -> birim ölçekleme.
    ///
    /// Eksen çevrimi ölçeklemeden önce yapılıyor ki "zemin" gerçekten en küçük
    /// Z olsun; zemine oturtma da ölçeklemeden önce ki kesit yükseklikleri
    /// metre cinsinden anlamlı kalsın.
    static func prepare(mesh: MeshData,
                        cloud: CloudSnapshot,
                        options: ExportOptions) -> PreparedScan {

        var m = mesh
        let allClasses = Set(SurfaceClass.allCases.map(\.rawValue))
        if options.classes != allClasses && !options.classes.isEmpty {
            m = m.filtered(classes: options.classes)
        }
        m = Decimator.decimate(m, cell: options.detail.cellSize)
        m = m.converted(to: options.upAxis)

        var c = cloud.converted(to: options.upAxis)

        // Hizalama Z ekseni etrafında döndürdüğü için sadece Z-yukarı anlamlı.
        var appliedYaw: Float?
        if options.alignToWalls, options.upAxis == .zUp,
           let yaw = WallAligner.dominantYaw(m), abs(yaw) > 1e-4 {
            m = WallAligner.rotate(m, byYaw: -yaw)
            c = WallAligner.rotate(c, byYaw: -yaw)
            appliedYaw = -yaw * 180 / .pi
        }

        var offset = SIMD3<Float>.zero
        if options.recenterToFloor, let b = m.bounds() {
            switch options.upAxis {
            case .zUp: offset = SIMD3<Float>(-b.center.x, -b.center.y, -b.min.z)
            case .yUp: offset = SIMD3<Float>(-b.center.x, -b.min.y, -b.center.z)
            }
            m = m.translated(by: offset)
            c = c.translated(by: offset)
        }

        let scale = options.unit.scaleFromMeters
        m = m.scaled(by: scale)
        c = c.scaled(by: scale)

        return PreparedScan(mesh: m,
                            cloud: c,
                            unit: options.unit,
                            sectionHeights: options.sectionHeights.map { $0 * scale },
                            appliedYawDegrees: appliedYaw)
    }

    /// Sadece üçgen sayısını merak ettiğimizde tam pipeline'ı çalıştırmaya gerek yok.
    static func previewTriangleCount(mesh: MeshData, options: ExportOptions) -> Int {
        var m = mesh
        let allClasses = Set(SurfaceClass.allCases.map(\.rawValue))
        if options.classes != allClasses && !options.classes.isEmpty {
            m = m.filtered(classes: options.classes)
        }
        m = Decimator.decimate(m, cell: options.detail.cellSize)
        return m.triangleCount
    }
}
