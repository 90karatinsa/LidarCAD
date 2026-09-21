import Foundation
import simd

/// Taramayı baskın duvar yönüne göre döndürür ("Manhattan" hizalama).
///
/// ARKit'in dünya ekseni, taramaya başladığınız andaki telefon yönüne göre
/// kurulur — yani duvarlarınız neredeyse hiçbir zaman X/Y eksenlerine paralel
/// çıkmaz. Fusion'da her skeç için ayrı bir construction plane kurmak zorunda
/// kalmamak için taramayı bir kere döndürüp dik hale getiriyoruz.
enum WallAligner {

    /// Z-yukarı mesh'te baskın yatay normal yönünün açısı (radyan).
    /// Duvarlar 90° periyotlu olduğu için açılar 4θ alanında toplanır;
    /// böylece birbirine dik dört duvar tek bir yönde birikir.
    /// - Returns: Baskın yön yeterince belirgin değilse `nil`.
    static func dominantYaw(_ mesh: MeshData, minVerticality: Float = 0.75) -> Float? {
        guard !mesh.isEmpty else { return nil }

        var sumCos = 0.0
        var sumSin = 0.0
        var totalWeight = 0.0

        for face in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[face * 3 + 0])]
            let b = mesh.positions[Int(mesh.indices[face * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[face * 3 + 2])]
            let cross = simd_cross(b - a, c - a)
            let doubleArea = simd_length(cross)
            guard doubleArea > 1e-9 else { continue }

            let n = cross / doubleArea
            // Yatay normal bileşeni baskın olmalı — zemin ve tavan katkı vermesin.
            let horizontal = sqrt(n.x * n.x + n.y * n.y)
            guard horizontal >= minVerticality else { continue }

            let weight = Double(doubleArea * 0.5)
            let theta = atan2(Double(n.y), Double(n.x))
            sumCos += weight * cos(4 * theta)
            sumSin += weight * sin(4 * theta)
            totalWeight += weight
        }

        guard totalWeight > 0 else { return nil }
        let magnitude = (sumCos * sumCos + sumSin * sumSin).squareRoot()
        // Dağınık yüzeylerde (eğri duvarlar, açık alan) hizalama yapma.
        guard magnitude > 0.2 * totalWeight else { return nil }

        return Float(atan2(sumSin, sumCos) / 4)
    }

    static func rotate(_ mesh: MeshData, byYaw yaw: Float) -> MeshData {
        guard yaw != 0 else { return mesh }
        let c = cos(yaw), s = sin(yaw)
        var out = mesh
        for i in out.positions.indices {
            let p = out.positions[i]
            out.positions[i] = SIMD3<Float>(p.x * c - p.y * s, p.x * s + p.y * c, p.z)
        }
        for i in out.normals.indices {
            let n = out.normals[i]
            out.normals[i] = SIMD3<Float>(n.x * c - n.y * s, n.x * s + n.y * c, n.z)
        }
        return out
    }

    static func rotate(_ cloud: CloudSnapshot, byYaw yaw: Float) -> CloudSnapshot {
        guard yaw != 0 else { return cloud }
        let c = cos(yaw), s = sin(yaw)
        var out = cloud
        for i in out.positions.indices {
            let p = out.positions[i]
            out.positions[i] = SIMD3<Float>(p.x * c - p.y * s, p.x * s + p.y * c, p.z)
        }
        return out
    }
}
