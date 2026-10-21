import Foundation
import ModelIO
import simd

/// Fotogrametrinin yazdığı USDZ'yi `MeshData`'ya okur; böylece mesh
/// telefondaki export hattının aynısından geçer (mm, Z yukarı, kesit...).
enum MeshLoader {

    enum Failure: LocalizedError {
        case unsupported(String)
        case empty
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "\(ext) biçimi okunamıyor"
            case .empty: return "Modelde üçgen bulunamadı"
            }
        }
    }

    static func load(_ url: URL) throws -> MeshData {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw Failure.unsupported(url.pathExtension)
        }
        let asset = MDLAsset(url: url)
        var out = MeshData()

        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let rotation = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                         SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                         SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))

            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition,
                                                           as: .float3) else { continue }
            let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let base = UInt32(out.positions.count)

            for i in 0..<mesh.vertexCount {
                // float3 öznitelikleri 12 byte paketli; SIMD3 olarak okumak taşar.
                let p = positions.dataStart.advanced(by: i * positions.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let w = world * SIMD4<Float>(p.0, p.1, p.2, 1)
                out.positions.append(SIMD3(w.x, w.y, w.z))

                if let normals {
                    let n = normals.dataStart.advanced(by: i * normals.stride)
                        .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                    let t = rotation * SIMD3(n.0, n.1, n.2)
                    let length = simd_length(t)
                    out.normals.append(length > 1e-6 ? t / length : SIMD3(0, 1, 0))
                } else {
                    out.normals.append(SIMD3(0, 1, 0))
                }
            }

            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                guard submesh.geometryType == .triangles else { continue }
                let indices = submesh.indexBuffer(asIndexType: .uInt32)
                let map = indices.map()
                let pointer = map.bytes.assumingMemoryBound(to: UInt32.self)
                for k in 0..<submesh.indexCount { out.indices.append(base + pointer[k]) }
                out.faceClasses.append(contentsOf:
                    [UInt8](repeating: SurfaceClass.none.rawValue, count: submesh.indexCount / 3))
            }
        }

        guard !out.isEmpty else { throw Failure.empty }
        return out
    }
}
