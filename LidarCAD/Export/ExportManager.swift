import Foundation
import simd

enum ExportError: LocalizedError {
    case emptyScan
    case noFormatSelected

    var errorDescription: String? {
        switch self {
        case .emptyScan:       return "Tarama boş. Önce bir yüzey tarayın."
        case .noFormatSelected: return "En az bir dosya formatı seçin."
        }
    }
}

enum ExportManager {

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func makeScanDirectory(name: String, baseDirectory: URL? = nil) throws -> URL {
        let root = (baseDirectory ?? documentsDirectory()).appendingPathComponent("Scans", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultScanName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "scan_" + f.string(from: date)
    }

    /// Seçili formatları diske yazar ve oluşan dosyaların URL'lerini döner.
    @discardableResult
    static func write(mesh: MeshData,
                      cloud: CloudSnapshot,
                      options: ExportOptions,
                      name: String,
                      baseDirectory: URL? = nil) throws -> [URL] {

        guard !options.formats.isEmpty else { throw ExportError.noFormatSelected }
        guard !mesh.isEmpty || !cloud.isEmpty else { throw ExportError.emptyScan }

        let prepared = MeshPipeline.prepare(mesh: mesh, cloud: cloud, options: options)
        let dir = try makeScanDirectory(name: name, baseDirectory: baseDirectory)
        var written: [URL] = []

        func save(_ data: Data, _ filename: String) throws {
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }

        let unit = prepared.unit

        if options.formats.contains(.obj), !prepared.mesh.isEmpty {
            try save(OBJWriter.data(from: prepared.mesh, unit: unit, name: name), "\(name).obj")
        }
        if options.formats.contains(.stl), !prepared.mesh.isEmpty {
            let header = "LidarCAD \(name) unit=\(unit.suffix)"
            try save(STLWriter.data(from: prepared.mesh, header: header), "\(name).stl")
        }
        if options.formats.contains(.plyMesh), !prepared.mesh.isEmpty {
            try save(PLYWriter.data(from: prepared.mesh, unit: unit), "\(name)_mesh.ply")
        }
        if options.formats.contains(.plyCloud), !prepared.cloud.isEmpty {
            try save(PLYWriter.data(from: prepared.cloud, unit: unit), "\(name)_cloud.ply")
        }
        if options.formats.contains(.dxf), !prepared.mesh.isEmpty {
            for (i, height) in prepared.sectionHeights.enumerated() {
                let segments = SectionSlicer.slice(prepared.mesh, atZ: height)
                guard !segments.isEmpty else { continue }
                let metres = options.sectionHeights[i]
                let tag = fixedString(metres, decimals: 2).replacingOccurrences(of: ".", with: "_")
                try save(DXFWriter.data(segments: segments, unit: unit),
                         "\(name)_kesit_\(tag)m.dxf")
            }
        }

        try save(Data(report(prepared: prepared, options: options, name: name).utf8), "OKUBENI.txt")
        return written
    }

    static func report(prepared: PreparedScan, options: ExportOptions, name: String) -> String {
        let unit = prepared.unit
        let d = unit.decimals
        var lines: [String] = []
        lines.append("LidarCAD — \(name)")
        lines.append(String(repeating: "=", count: 40))
        lines.append("Birim         : \(unit.label)")
        lines.append("Yukarı eksen  : \(options.upAxis.label)")
        lines.append("Sadeleştirme  : \(options.detail.label)")
        lines.append("Üçgen sayısı  : \(prepared.mesh.triangleCount)")
        lines.append("Vertex sayısı : \(prepared.mesh.vertexCount)")
        lines.append("Nokta bulutu  : \(prepared.cloud.count) nokta")

        if let b = prepared.mesh.bounds() {
            let s = b.size
            lines.append("Ölçüler (GxDxY): "
                + "\(fixedString(s.x, decimals: d)) x "
                + "\(fixedString(s.y, decimals: d)) x "
                + "\(fixedString(s.z, decimals: d)) \(unit.suffix)")
        }
        if let yaw = prepared.appliedYawDegrees {
            lines.append("Duvar hizası : \(fixedString(yaw, decimals: 2))° döndürüldü")
        } else if options.alignToWalls {
            lines.append("Duvar hizası : baskın yön bulunamadı, döndürülmedi")
        }
        if options.recenterToFloor {
            lines.append("Konum         : XY'de ortalandı, zemin Z=0'a oturtuldu")
        } else {
            lines.append("Konum         : tarama başlangıç noktasına göre (ARKit origin)")
        }

        lines.append("")
        lines.append("FUSION 360'A ALMA")
        lines.append(String(repeating: "-", count: 40))
        lines.append("1) Kesit (önerilen yol):")
        lines.append("   Insert > Insert DXF > .dxf dosyasını seç > bir düzlem seç.")
        lines.append("   Kesit skeç olarak gelir; üstünden ölçülü, temiz geometri çizin.")
        lines.append("2) Mesh referansı:")
        lines.append("   Insert > Insert Mesh > .obj veya .stl. Unit Type = \(unit.suffix).")
        lines.append("   Mesh ağır gelirse Mesh sekmesinde Modify > Reduce kullanın.")
        lines.append("3) Katı modele çevirme (isteğe bağlı):")
        lines.append("   Mesh > Modify > Convert Mesh. Yüzey sayısı ~50.000'in altında olmalı;")
        lines.append("   bunun için export'ta 'Kaba (6 cm)' seçeneğiyle yeniden alın.")
        lines.append("")
        lines.append("NOT: STL birimsiz bir formattır, mm olarak yorumlanır.")
        lines.append("Tarama doğruluğunu bilinen bir ölçüyle (kapı genişliği gibi)")
        lines.append("Fusion içinde Measure ile doğrulayın; sapma varsa Scale uygulayın.")
        return lines.joined(separator: "\n") + "\n"
    }
}
