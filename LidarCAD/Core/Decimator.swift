import Foundation
import simd

/// Vertex-clustering (grid snapping) sadeleştirme.
///
/// ARKit'in ürettiği mesh Fusion 360'a doğrudan sokulamayacak kadar yoğun ve
/// gürültülü oluyor. Bu yöntem O(n) çalışır, topolojiyi kabaca korur ve
/// aynı zamanda tarama gürültüsünü ortalayarak yüzeyleri düzleştirir —
/// CAD referansı için istenen tam olarak bu.
enum Decimator {

    /// - Parameter cell: küp hücre kenarı, metre. 0 veya negatif ise sadeleştirme yapılmaz.
    static func decimate(_ mesh: MeshData, cell: Float) -> MeshData {
        guard cell > 0, !mesh.isEmpty else { return mesh }

        let inv = 1 / cell
        let hasNormals = mesh.normals.count == mesh.positions.count

        var cellIndex = [SIMD3<Int32>: Int]()
        cellIndex.reserveCapacity(mesh.positions.count / 4 + 16)

        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        var posSum = [SIMD3<Double>]()
        var nrmSum = [SIMD3<Double>]()
        var counts = [Double]()

        for (i, p) in mesh.positions.enumerated() {
            let key = SIMD3<Int32>(
                Int32((p.x * inv).rounded(.down)),
                Int32((p.y * inv).rounded(.down)),
                Int32((p.z * inv).rounded(.down))
            )
            if let existing = cellIndex[key] {
                remap[i] = UInt32(existing)
                posSum[existing] += SIMD3<Double>(p)
                if hasNormals { nrmSum[existing] += SIMD3<Double>(mesh.normals[i]) }
                counts[existing] += 1
            } else {
                let new = posSum.count
                cellIndex[key] = new
                remap[i] = UInt32(new)
                posSum.append(SIMD3<Double>(p))
                nrmSum.append(hasNormals ? SIMD3<Double>(mesh.normals[i]) : .zero)
                counts.append(1)
            }
        }

        var out = MeshData()
        out.positions.reserveCapacity(posSum.count)
        out.normals.reserveCapacity(hasNormals ? posSum.count : 0)

        for i in 0..<posSum.count {
            let c = counts[i]
            out.positions.append(SIMD3<Float>(posSum[i] / c))
            if hasNormals {
                let n = SIMD3<Float>(nrmSum[i] / c)
                let len = simd_length(n)
                out.normals.append(len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0))
            }
        }

        out.indices.reserveCapacity(mesh.indices.count)
        out.faceClasses.reserveCapacity(mesh.triangleCount)

        for face in 0..<mesh.triangleCount {
            let a = remap[Int(mesh.indices[face * 3 + 0])]
            let b = remap[Int(mesh.indices[face * 3 + 1])]
            let c = remap[Int(mesh.indices[face * 3 + 2])]
            // Aynı hücreye düşen üçgenler yok olur.
            if a == b || b == c || a == c { continue }
            out.indices.append(a)
            out.indices.append(b)
            out.indices.append(c)
            out.faceClasses.append(face < mesh.faceClasses.count ? mesh.faceClasses[face] : 0)
        }

        // Hücre birleştirme sonrası öksüz kalan vertexleri at.
        return out.compacted()
    }
}

extension MeshData {
    /// Hiçbir üçgen tarafından kullanılmayan vertexleri temizler.
    func compacted() -> MeshData {
        guard !positions.isEmpty else { return self }
        var used = [Bool](repeating: false, count: positions.count)
        for i in indices { used[Int(i)] = true }
        if !used.contains(false) { return self }

        var remap = [UInt32](repeating: 0, count: positions.count)
        let hasNormals = normals.count == positions.count
        var out = MeshData()
        out.faceClasses = faceClasses
        out.indices = indices

        for i in 0..<positions.count where used[i] {
            remap[i] = UInt32(out.positions.count)
            out.positions.append(positions[i])
            if hasNormals { out.normals.append(normals[i]) }
        }
        for k in out.indices.indices { out.indices[k] = remap[Int(out.indices[k])] }
        return out
    }
}
