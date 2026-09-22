import Foundation
import simd

/// Dünya uzayında eksen hizalı kırpma kutusu.
///
/// Bölge taramasının çekirdeği: torpidodaki teyp yuvası gibi bir hacmi
/// sınırlayıp taramanın geri kalanını (koltuk, direksiyon, cam) atmak.
/// Kalan mesh hem Fusion'da yönetilebilir olur hem de kesitler temiz çıkar.
struct CropBox: Equatable, Codable {
    /// Metre, ARKit dünya uzayı.
    var center: SIMD3<Float>
    /// Kenar uzunlukları, metre.
    var size: SIMD3<Float>

    var minimum: SIMD3<Float> { center - size * 0.5 }
    var maximum: SIMD3<Float> { center + size * 0.5 }

    func contains(_ point: SIMD3<Float>) -> Bool {
        let lo = minimum, hi = maximum
        return point.x >= lo.x && point.x <= hi.x
            && point.y >= lo.y && point.y <= hi.y
            && point.z >= lo.z && point.z <= hi.z
    }
}

extension MeshData {
    /// Ağırlık merkezi kutunun dışında kalan üçgenleri atar.
    ///
    /// Üçgenleri düzlemde kesmek yerine tamamını tutup atıyoruz: kenarda
    /// birkaç santim taşma olur ama mesh su geçirmez kalır ve kesit alırken
    /// yapay açık kenarlar oluşmaz.
    func cropped(to box: CropBox) -> MeshData {
        guard !isEmpty else { return self }

        var out = MeshData()
        var remap = [Int32](repeating: -1, count: positions.count)
        let hasNormals = normals.count == positions.count

        for face in 0..<triangleCount {
            let ia = Int(indices[face * 3 + 0])
            let ib = Int(indices[face * 3 + 1])
            let ic = Int(indices[face * 3 + 2])
            let centroid = (positions[ia] + positions[ib] + positions[ic]) / 3
            guard box.contains(centroid) else { continue }

            for old in [ia, ib, ic] {
                var mapped = remap[old]
                if mapped < 0 {
                    mapped = Int32(out.positions.count)
                    remap[old] = mapped
                    out.positions.append(positions[old])
                    if hasNormals { out.normals.append(normals[old]) }
                }
                out.indices.append(UInt32(mapped))
            }
            out.faceClasses.append(face < faceClasses.count ? faceClasses[face] : 0)
        }
        return out
    }
}

extension CloudSnapshot {
    func cropped(to box: CropBox) -> CloudSnapshot {
        guard !isEmpty else { return self }
        var out = CloudSnapshot()
        let hasColors = colors.count == positions.count
        for (i, p) in positions.enumerated() where box.contains(p) {
            out.positions.append(p)
            if hasColors { out.colors.append(colors[i]) }
        }
        return out
    }
}
