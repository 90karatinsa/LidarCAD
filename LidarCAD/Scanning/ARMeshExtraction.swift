import ARKit
import simd

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

/// ARKit'in `ARMeshAnchor` yığınını tek bir dünya uzayı mesh'ine düzleştirir.
enum ARMeshExtractor {

    static func snapshot(anchors: [ARMeshAnchor]) -> MeshData {
        var out = MeshData()

        var vertexTotal = 0
        var faceTotal = 0
        for anchor in anchors {
            vertexTotal += anchor.geometry.vertices.count
            faceTotal += anchor.geometry.faces.count
        }
        out.positions.reserveCapacity(vertexTotal)
        out.normals.reserveCapacity(vertexTotal)
        out.indices.reserveCapacity(faceTotal * 3)
        out.faceClasses.reserveCapacity(faceTotal)

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let rotation = simd_float3x3(transform.columns.0.xyz,
                                         transform.columns.1.xyz,
                                         transform.columns.2.xyz)
            let base = UInt32(out.positions.count)

            // DİKKAT: buffer'daki vertexler 12 byte aralıkla paketli,
            // SIMD3<Float> ise bellekte 16 byte yer kaplar. Doğrudan
            // SIMD3 olarak okumak son elemanda buffer dışına taşar —
            // bu yüzden (Float, Float, Float) tuple'ı üzerinden okuyoruz.
            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let raw = vertexBase
                    .advanced(by: vertices.offset + vertices.stride * i)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let world = transform * SIMD4<Float>(raw.0, raw.1, raw.2, 1)
                out.positions.append(world.xyz)
            }

            let normals = geometry.normals
            if normals.count == vertices.count {
                let normalBase = normals.buffer.contents()
                for i in 0..<normals.count {
                    let raw = normalBase
                        .advanced(by: normals.offset + normals.stride * i)
                        .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                    // Anchor transform'u rijit olduğu için normal için
                    // ters-transpoz gerekmiyor, saf rotasyon yeterli.
                    let n = rotation * SIMD3<Float>(raw.0, raw.1, raw.2)
                    let length = simd_length(n)
                    out.normals.append(length > 1e-6 ? n / length : SIMD3<Float>(0, 1, 0))
                }
            } else {
                out.normals.append(contentsOf:
                    [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: vertices.count))
            }

            let faces = geometry.faces
            guard faces.bytesPerIndex == MemoryLayout<UInt32>.size,
                  faces.indexCountPerPrimitive == 3 else { continue }
            let indexBase = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<(faces.count * 3) {
                out.indices.append(base + indexBase[i])
            }

            if let classification = geometry.classification,
               classification.count == faces.count {
                let classBase = classification.buffer.contents()
                for i in 0..<faces.count {
                    let value = classBase
                        .advanced(by: classification.offset + classification.stride * i)
                        .assumingMemoryBound(to: UInt8.self).pointee
                    out.faceClasses.append(value)
                }
            } else {
                out.faceClasses.append(contentsOf:
                    [UInt8](repeating: SurfaceClass.none.rawValue, count: faces.count))
            }
        }

        return out
    }
}
