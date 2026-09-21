import Foundation
import simd

/// Mesh'i yatay bir düzlemle kesip 2B çizgi parçaları üretir.
///
/// Fusion 360 iş akışının can damarı bu: çıkan DXF'i `Insert > Insert DXF` ile
/// doğrudan bir skeç'e alıp üstünden temiz geometri çizersiniz. Gürültülü mesh'i
/// katı modele çevirmeye çalışmaktan çok daha kullanışlı.
enum SectionSlicer {

    struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
    }

    /// Z = `height` düzlemiyle kesişim. Mesh'in Z-yukarı sisteminde olduğu varsayılır.
    /// - Returns: XY düzleminde çizgi parçaları.
    static func slice(_ mesh: MeshData, atZ height: Float, minLength: Float = 1e-5) -> [Segment] {
        guard !mesh.isEmpty else { return [] }
        var segments: [Segment] = []
        segments.reserveCapacity(mesh.triangleCount / 8 + 16)

        var v = [SIMD3<Float>](repeating: .zero, count: 3)
        var d = [Float](repeating: 0, count: 3)
        var hits = [SIMD2<Float>]()
        hits.reserveCapacity(3)

        for face in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[face * 3 + k])]
                v[k] = p
                d[k] = p.z - height
            }

            // Tamamen bir tarafta kalan üçgenleri ucuz şekilde ele.
            if (d[0] < 0 && d[1] < 0 && d[2] < 0) || (d[0] >= 0 && d[1] >= 0 && d[2] >= 0) {
                continue
            }

            hits.removeAll(keepingCapacity: true)
            // `< 0` ve `>= 0` ayrımı tutarlı kullanıldığı için düzlem üstünde
            // duran vertexler iki kez sayılmaz.
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let di = d[i], dj = d[j]
                let crosses = (di < 0 && dj >= 0) || (di >= 0 && dj < 0)
                guard crosses else { continue }
                let t = di / (di - dj)
                let p = v[i] + (v[j] - v[i]) * t
                hits.append(SIMD2<Float>(p.x, p.y))
            }

            guard hits.count == 2 else { continue }
            guard simd_distance(hits[0], hits[1]) > minLength else { continue }
            segments.append(Segment(a: hits[0], b: hits[1]))
        }
        return segments
    }

    /// Dikey kesit (elevation): X = `offset` düzlemi. Sonuç (Y, Z) düzlemine düşer.
    static func sliceVertical(_ mesh: MeshData, atX offset: Float, minLength: Float = 1e-5) -> [Segment] {
        guard !mesh.isEmpty else { return [] }
        var segments: [Segment] = []
        var v = [SIMD3<Float>](repeating: .zero, count: 3)
        var d = [Float](repeating: 0, count: 3)
        var hits = [SIMD2<Float>]()

        for face in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[face * 3 + k])]
                v[k] = p
                d[k] = p.x - offset
            }
            if (d[0] < 0 && d[1] < 0 && d[2] < 0) || (d[0] >= 0 && d[1] >= 0 && d[2] >= 0) { continue }

            hits.removeAll(keepingCapacity: true)
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let di = d[i], dj = d[j]
                let crosses = (di < 0 && dj >= 0) || (di >= 0 && dj < 0)
                guard crosses else { continue }
                let t = di / (di - dj)
                let p = v[i] + (v[j] - v[i]) * t
                hits.append(SIMD2<Float>(p.y, p.z))
            }
            guard hits.count == 2, simd_distance(hits[0], hits[1]) > minLength else { continue }
            segments.append(Segment(a: hits[0], b: hits[1]))
        }
        return segments
    }
}
