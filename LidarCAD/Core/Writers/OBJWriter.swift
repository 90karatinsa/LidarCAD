import Foundation
import simd

/// Wavefront OBJ. Fusion 360 `Insert > Insert Mesh` ile okur;
/// Blender/MeshLab/CloudCompare için de ortak payda.
enum OBJWriter {

    static func data(from mesh: MeshData, unit: LengthUnit, name: String) -> Data {
        var out = TextBuffer()
        let d = unit.decimals
        let hasNormals = mesh.normals.count == mesh.positions.count

        out.line("# LidarCAD")
        out.line("# birim: \(unit.suffix)")
        out.line("# vertex: \(mesh.vertexCount)  ucgen: \(mesh.triangleCount)")
        out.line("o \(sanitize(name))")

        for p in mesh.positions {
            out.line("v \(fixedString(p.x, decimals: d)) \(fixedString(p.y, decimals: d)) \(fixedString(p.z, decimals: d))")
        }
        if hasNormals {
            for n in mesh.normals {
                out.line("vn \(fixedString(n.x, decimals: 4)) \(fixedString(n.y, decimals: 4)) \(fixedString(n.z, decimals: 4))")
            }
        }

        // OBJ indisleri 1 tabanlı.
        for face in 0..<mesh.triangleCount {
            let a = mesh.indices[face * 3 + 0] + 1
            let b = mesh.indices[face * 3 + 1] + 1
            let c = mesh.indices[face * 3 + 2] + 1
            if hasNormals {
                out.line("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            } else {
                out.line("f \(a) \(b) \(c)")
            }
        }
        return out.finalized()
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                ? Character(scalar) : "_"
        }
        let result = String(allowed)
        return result.isEmpty ? "scan" : result
    }
}
