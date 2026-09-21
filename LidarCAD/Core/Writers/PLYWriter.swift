import Foundation
import simd

/// binary_little_endian PLY. CloudCompare, MeshLab ve Rhino'nun ana giriş formatı.
/// (Fusion 360 nokta bulutu okumaz — PLY ölçüm ve temizlik aşaması için.)
enum PLYWriter {

    static func data(from cloud: CloudSnapshot, unit: LengthUnit) -> Data {
        let n = cloud.count
        let hasColor = cloud.colors.count == n

        var header = """
        ply
        format binary_little_endian 1.0
        comment LidarCAD
        comment birim: \(unit.suffix)
        element vertex \(n)
        property float x
        property float y
        property float z

        """
        if hasColor {
            header += """
            property uchar red
            property uchar green
            property uchar blue

            """
        }
        header += "end_header\n"

        let stride = hasColor ? 15 : 12
        var buffer = BinaryBuffer(reservingCapacity: header.utf8.count + n * stride)
        buffer.append(ascii: header)

        for i in 0..<n {
            let p = cloud.positions[i]
            buffer.append(p.x); buffer.append(p.y); buffer.append(p.z)
            if hasColor {
                let c = cloud.colors[i]
                buffer.append(c.x); buffer.append(c.y); buffer.append(c.z)
            }
        }
        return buffer.data
    }

    /// Mesh PLY — MeshLab'de delik kapatma / Poisson için OBJ'den daha pratik,
    /// ayrıca üçgen başına sınıf bilgisini de taşıyabiliyor.
    static func data(from mesh: MeshData, unit: LengthUnit) -> Data {
        let vertexCount = mesh.vertexCount
        let faceCount = mesh.triangleCount
        let hasNormals = mesh.normals.count == vertexCount
        let hasClasses = mesh.faceClasses.count == faceCount

        var header = """
        ply
        format binary_little_endian 1.0
        comment LidarCAD
        comment birim: \(unit.suffix)
        element vertex \(vertexCount)
        property float x
        property float y
        property float z

        """
        if hasNormals {
            header += """
            property float nx
            property float ny
            property float nz

            """
        }
        header += "element face \(faceCount)\n"
        header += "property list uchar int vertex_indices\n"
        if hasClasses { header += "property uchar class\n" }
        header += "end_header\n"

        let vertexStride = hasNormals ? 24 : 12
        let faceStride = 13 + (hasClasses ? 1 : 0)
        var buffer = BinaryBuffer(reservingCapacity: header.utf8.count + vertexCount * vertexStride + faceCount * faceStride)
        buffer.append(ascii: header)

        for i in 0..<vertexCount {
            let p = mesh.positions[i]
            buffer.append(p.x); buffer.append(p.y); buffer.append(p.z)
            if hasNormals {
                let n = mesh.normals[i]
                buffer.append(n.x); buffer.append(n.y); buffer.append(n.z)
            }
        }
        for face in 0..<faceCount {
            buffer.append(UInt8(3))
            buffer.append(UInt32(mesh.indices[face * 3 + 0]))
            buffer.append(UInt32(mesh.indices[face * 3 + 1]))
            buffer.append(UInt32(mesh.indices[face * 3 + 2]))
            if hasClasses { buffer.append(mesh.faceClasses[face]) }
        }
        return buffer.data
    }
}
