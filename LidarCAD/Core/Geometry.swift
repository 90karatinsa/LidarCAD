import Foundation
import simd

// MARK: - Yüzey sınıfları (ARMeshClassification ile birebir aynı raw value)

enum SurfaceClass: UInt8, CaseIterable, Identifiable, Codable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .none:    return "Sınıflandırılmamış"
        case .wall:    return "Duvar"
        case .floor:   return "Zemin"
        case .ceiling: return "Tavan"
        case .table:   return "Masa"
        case .seat:    return "Oturma"
        case .window:  return "Pencere"
        case .door:    return "Kapı"
        }
    }
}

// MARK: - Birimler

enum LengthUnit: String, CaseIterable, Identifiable, Codable {
    case millimeters
    case centimeters
    case meters

    var id: String { rawValue }

    /// ARKit metre cinsinden çalışır; bu çarpan metreyi hedef birime çevirir.
    var scaleFromMeters: Float {
        switch self {
        case .millimeters: return 1000
        case .centimeters: return 100
        case .meters:      return 1
        }
    }

    var label: String {
        switch self {
        case .millimeters: return "Milimetre (mm)"
        case .centimeters: return "Santimetre (cm)"
        case .meters:      return "Metre (m)"
        }
    }

    var suffix: String {
        switch self {
        case .millimeters: return "mm"
        case .centimeters: return "cm"
        case .meters:      return "m"
        }
    }

    /// DXF $INSUNITS grup kodu değeri.
    var dxfInsUnits: Int {
        switch self {
        case .millimeters: return 4
        case .centimeters: return 5
        case .meters:      return 6
        }
    }

    /// Metin formatlarında yazılacak ondalık basamak sayısı (~mikron çözünürlük).
    var decimals: Int {
        switch self {
        case .millimeters: return 3
        case .centimeters: return 4
        case .meters:      return 6
        }
    }
}

// MARK: - Yukarı eksen

enum UpAxis: String, CaseIterable, Identifiable, Codable {
    /// Fusion 360, AutoCAD, SolidWorks varsayılanı.
    case zUp
    /// ARKit / Blender-glTF native.
    case yUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zUp: return "Z yukarı (Fusion 360, AutoCAD)"
        case .yUp: return "Y yukarı (ARKit, glTF)"
        }
    }
}

// MARK: - Mesh verisi

struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Üçgen başına 3 indis.
    var indices: [UInt32] = []
    /// Üçgen başına 1 sınıf (SurfaceClass.rawValue).
    var faceClasses: [UInt8] = []

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.count < 3 }
}

struct Bounds {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> { max - min }
    var center: SIMD3<Float> { (min + max) * 0.5 }
}

extension MeshData {

    func bounds() -> Bounds? {
        guard let first = positions.first else { return nil }
        var lo = first, hi = first
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return Bounds(min: lo, max: hi)
    }

    /// Sadece verilen sınıflara ait üçgenleri tutar ve kullanılmayan vertexleri atar.
    func filtered(classes: Set<UInt8>) -> MeshData {
        guard !faceClasses.isEmpty else { return self }

        var out = MeshData()
        var remap = [Int32](repeating: -1, count: positions.count)
        let hasNormals = normals.count == positions.count

        out.indices.reserveCapacity(indices.count)
        out.faceClasses.reserveCapacity(faceClasses.count)

        for face in 0..<triangleCount {
            let cls = face < faceClasses.count ? faceClasses[face] : 0
            guard classes.contains(cls) else { continue }

            for k in 0..<3 {
                let old = Int(indices[face * 3 + k])
                var mapped = remap[old]
                if mapped < 0 {
                    mapped = Int32(out.positions.count)
                    remap[old] = mapped
                    out.positions.append(positions[old])
                    if hasNormals { out.normals.append(normals[old]) }
                }
                out.indices.append(UInt32(mapped))
            }
            out.faceClasses.append(cls)
        }
        return out
    }

    /// ARKit (Y yukarı, -Z ileri) -> hedef eksen sistemi.
    func converted(to axis: UpAxis) -> MeshData {
        guard axis == .zUp else { return self }
        var out = self
        // (x, y, z) -> (x, -z, y). X ekseni etrafında +90°, sağ el sistemi korunur.
        for i in out.positions.indices {
            let p = out.positions[i]
            out.positions[i] = SIMD3<Float>(p.x, -p.z, p.y)
        }
        for i in out.normals.indices {
            let n = out.normals[i]
            out.normals[i] = SIMD3<Float>(n.x, -n.z, n.y)
        }
        return out
    }

    func translated(by offset: SIMD3<Float>) -> MeshData {
        guard offset != .zero else { return self }
        var out = self
        for i in out.positions.indices { out.positions[i] += offset }
        return out
    }

    func scaled(by factor: Float) -> MeshData {
        guard factor != 1 else { return self }
        var out = self
        for i in out.positions.indices { out.positions[i] *= factor }
        return out
    }

    /// Üçgenin geometrik normali (sarım yönünden).
    func faceNormal(_ face: Int) -> SIMD3<Float> {
        let a = positions[Int(indices[face * 3 + 0])]
        let b = positions[Int(indices[face * 3 + 1])]
        let c = positions[Int(indices[face * 3 + 2])]
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        return len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1)
    }
}

// MARK: - Nokta bulutu anlık görüntüsü

struct CloudSnapshot {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []

    var count: Int { positions.count }
    var isEmpty: Bool { positions.isEmpty }

    func converted(to axis: UpAxis) -> CloudSnapshot {
        guard axis == .zUp else { return self }
        var out = self
        for i in out.positions.indices {
            let p = out.positions[i]
            out.positions[i] = SIMD3<Float>(p.x, -p.z, p.y)
        }
        return out
    }

    func translated(by offset: SIMD3<Float>) -> CloudSnapshot {
        guard offset != .zero else { return self }
        var out = self
        for i in out.positions.indices { out.positions[i] += offset }
        return out
    }

    func scaled(by factor: Float) -> CloudSnapshot {
        guard factor != 1 else { return self }
        var out = self
        for i in out.positions.indices { out.positions[i] *= factor }
        return out
    }
}

// MARK: - Hızlı sabit ondalık formatlayıcı
//
// String(format:) metin export'unda yüz binlerce kez çağrıldığı için pahalı.
// Bu sürüm tamsayı aritmetiğiyle çalışır ve asla bilimsel gösterim üretmez
// (Fusion'ın DXF/OBJ okuyucusu 1e-05 gibi değerlerde takılabiliyor).

@inline(__always)
func fixedString(_ value: Float, decimals: Int) -> String {
    guard value.isFinite else { return "0" }
    var scale = 1.0
    for _ in 0..<decimals { scale *= 10 }
    let scaled = (Double(value) * scale).rounded()
    guard scaled.magnitude < 9.0e18 else { return "0" }

    var n = Int64(scaled)
    let negative = n < 0
    if negative { n = -n }

    var digits = String(n)
    if decimals > 0 {
        while digits.count <= decimals { digits = "0" + digits }
        let split = digits.index(digits.endIndex, offsetBy: -decimals)
        digits = String(digits[..<split]) + "." + String(digits[split...])
    }
    return negative ? "-" + digits : digits
}
