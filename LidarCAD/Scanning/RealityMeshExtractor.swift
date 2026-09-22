import RealityKit
import simd

/// RealityKit varlık ağacını düz bir `MeshData`'ya çevirir.
///
/// `PhotogrammetrySession` sonucu `ModelEntity` olarak verebiliyor; böylece
/// USDZ yazıp tekrar ayrıştırmaya gerek kalmıyor, mesh doğrudan bellekte
/// export hattına giriyor.
@MainActor
enum RealityMeshExtractor {

    static func extract(from entity: Entity) -> MeshData {
        var out = MeshData()
        append(entity, parentTransform: matrix_identity_float4x4, into: &out)
        return out
    }

    private static func append(_ entity: Entity,
                               parentTransform: simd_float4x4,
                               into out: inout MeshData) {

        let world = parentTransform * entity.transform.matrix

        if let model = entity.components[ModelComponent.self] {
            let rotation = simd_float3x3(world.columns.0.xyz,
                                         world.columns.1.xyz,
                                         world.columns.2.xyz)

            for meshModel in model.mesh.contents.models {
                for part in meshModel.parts {
                    let positions = part.positions.elements
                    guard !positions.isEmpty else { continue }
                    let indices = part.triangleIndices?.elements ?? []
                    let base = UInt32(out.positions.count)

                    for p in positions {
                        let w = world * SIMD4<Float>(p.x, p.y, p.z, 1)
                        out.positions.append(SIMD3<Float>(w.x, w.y, w.z))
                    }

                    if let normals = part.normals?.elements, normals.count == positions.count {
                        for n in normals {
                            let t = rotation * n
                            let length = simd_length(t)
                            out.normals.append(length > 1e-6 ? t / length : SIMD3<Float>(0, 1, 0))
                        }
                    } else {
                        out.normals.append(contentsOf:
                            [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: positions.count))
                    }

                    for i in indices { out.indices.append(base + i) }
                    out.faceClasses.append(contentsOf:
                        [UInt8](repeating: SurfaceClass.none.rawValue, count: indices.count / 3))
                }
            }
        }

        for child in entity.children {
            append(child, parentTransform: world, into: &out)
        }
    }
}
