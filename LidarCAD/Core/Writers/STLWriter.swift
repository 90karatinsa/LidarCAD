import Foundation
import simd

/// Binary STL. Birimsiz bir format olduğu için geleneksel olarak mm kabul edilir —
/// Fusion 360'a sokarken export biriminizi mm seçmeniz en güvenlisi.
enum STLWriter {

    static func data(from mesh: MeshData, header: String) -> Data {
        let triangles = mesh.triangleCount
        var buffer = BinaryBuffer(reservingCapacity: 84 + triangles * 50)

        // 80 byte başlık. "solid" ile başlamamalı, yoksa ASCII STL sanılır.
        var headerBytes = Array(header.utf8.prefix(79))
        headerBytes.append(contentsOf: [UInt8](repeating: 0, count: 80 - headerBytes.count))
        buffer.append(rawBytes: headerBytes)
        buffer.append(UInt32(triangles))

        for face in 0..<triangles {
            let ia = Int(mesh.indices[face * 3 + 0])
            let ib = Int(mesh.indices[face * 3 + 1])
            let ic = Int(mesh.indices[face * 3 + 2])
            let a = mesh.positions[ia]
            let b = mesh.positions[ib]
            let c = mesh.positions[ic]

            // Saklanan normal çoğu okuyucu tarafından yok sayılır ama
            // sarım yönüyle tutarlı olsun diye geometrik olarak hesaplıyoruz.
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let n = length > 1e-12 ? cross / length : SIMD3<Float>(0, 0, 0)

            buffer.append(n.x); buffer.append(n.y); buffer.append(n.z)
            buffer.append(a.x); buffer.append(a.y); buffer.append(a.z)
            buffer.append(b.x); buffer.append(b.y); buffer.append(b.z)
            buffer.append(c.x); buffer.append(c.y); buffer.append(c.z)
            buffer.append(UInt16(0)) // attribute byte count
        }
        return buffer.data
    }
}
