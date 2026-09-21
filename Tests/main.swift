// macOS doğrulama koşucusu. ARKit'e dokunmayan Core + Export kodunu
// gerçek sayılarla sınar:  swiftc ... && ./verify
import Foundation
import simd

var failures = 0
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)\(d.isEmpty ? "" : "  -> \(d)")")
    }
}

func near(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) <= eps }

// MARK: - Test verisi: 2 m x 3 m x 2.5 m eksen hizalı kutu (ARKit Y-yukarı, metre)
// min köşe (0,0,0), max köşe (2, 2.5, -3)  -> ARKit'te ileri yön -Z

func makeBox(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> MeshData {
    let c: [SIMD3<Float>] = [
        SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
        SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
        SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
        SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
    ]
    let faces: [(Int, Int, Int)] = [
        (0,2,1),(0,3,2), (4,5,6),(4,6,7),
        (0,1,5),(0,5,4), (2,3,7),(2,7,6),
        (1,2,6),(1,6,5), (0,4,7),(0,7,3),
    ]
    var m = MeshData()
    m.positions = c
    m.normals = c.map { simd_normalize($0 - (lo + hi) * 0.5) }
    for f in faces {
        m.indices.append(contentsOf: [UInt32(f.0), UInt32(f.1), UInt32(f.2)])
    }
    // 0-1 zemin, 2-3 tavan, geri kalanı duvar
    m.faceClasses = [SurfaceClass.floor.rawValue, SurfaceClass.floor.rawValue,
                     SurfaceClass.ceiling.rawValue, SurfaceClass.ceiling.rawValue]
                  + [UInt8](repeating: SurfaceClass.wall.rawValue, count: 8)
    return m
}

let box = makeBox(min: SIMD3(0, 0, 0), max: SIMD3(2, 2.5, -3))

// MARK: - fixedString

print("\n[fixedString]")
check("tam sayı", fixedString(1234.5, decimals: 3) == "1234.500", fixedString(1234.5, decimals: 3))
check("negatif", fixedString(-0.5, decimals: 3) == "-0.500", fixedString(-0.5, decimals: 3))
check("sıfıra yakın bilimsel gösterim yok",
      fixedString(1e-5, decimals: 6) == "0.000010", fixedString(1e-5, decimals: 6))
check("çok küçük -> sıfır", fixedString(1e-9, decimals: 3) == "0.000", fixedString(1e-9, decimals: 3))
check("yuvarlama", fixedString(0.0006, decimals: 3) == "0.001", fixedString(0.0006, decimals: 3))
check("sıfır ondalık", fixedString(42.7, decimals: 0) == "43", fixedString(42.7, decimals: 0))
check("NaN güvenli", fixedString(Float.nan, decimals: 3) == "0")
check("sonsuz güvenli", fixedString(Float.infinity, decimals: 3) == "0")

// MARK: - Eksen çevrimi

print("\n[eksen çevrimi]")
let zup = box.converted(to: .zUp)
// ARKit (x, y, z) -> (x, -z, y)
check("Y-yukarı yüksekliği Z'ye taşındı",
      near(zup.bounds()!.size.z, 2.5), "\(zup.bounds()!.size)")
check("derinlik Y'ye taşındı", near(zup.bounds()!.size.y, 3))
check("genişlik X'te kaldı", near(zup.bounds()!.size.x, 2))
check("sağ el sistemi korundu (determinant +1)", {
    let m = simd_float3x3(SIMD3<Float>(1,0,0), SIMD3<Float>(0,0,1), SIMD3<Float>(0,-1,0))
    return near(m.determinant, 1)
}())
check("yUp kimlik dönüşümü", box.converted(to: .yUp).positions == box.positions)

// MARK: - Sınıf filtresi

print("\n[sınıf filtresi]")
let wallsOnly = box.filtered(classes: [SurfaceClass.wall.rawValue])
check("sadece duvar üçgenleri", wallsOnly.triangleCount == 8, "\(wallsOnly.triangleCount)")
check("kullanılmayan vertex kalmadı", wallsOnly.vertexCount == 8, "\(wallsOnly.vertexCount)")
check("indisler sınırlar içinde", wallsOnly.indices.allSatisfy { Int($0) < wallsOnly.vertexCount })
let floorOnly = box.filtered(classes: [SurfaceClass.floor.rawValue])
check("zemin 2 üçgen", floorOnly.triangleCount == 2)
check("zemin 4 vertex", floorOnly.vertexCount == 4, "\(floorOnly.vertexCount)")

// MARK: - Sadeleştirme

print("\n[sadeleştirme]")
// Yoğun bir ızgara düzlem: 1 m x 1 m, 2 cm adım
var grid = MeshData()
let n = 51
for j in 0..<n { for i in 0..<n {
    grid.positions.append(SIMD3<Float>(Float(i) * 0.02, 0, Float(j) * 0.02))
    grid.normals.append(SIMD3<Float>(0, 1, 0))
}}
for j in 0..<(n-1) { for i in 0..<(n-1) {
    let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
    grid.indices.append(contentsOf: [a, c, b, b, c, d])
    grid.faceClasses.append(contentsOf: [SurfaceClass.floor.rawValue, SurfaceClass.floor.rawValue])
}}
check("ızgara kuruldu", grid.triangleCount == 5000, "\(grid.triangleCount)")

let dec = Decimator.decimate(grid, cell: 0.10)
check("üçgen sayısı ciddi düştü", dec.triangleCount < grid.triangleCount / 8,
      "\(grid.triangleCount) -> \(dec.triangleCount)")
check("üçgen kaldı", dec.triangleCount > 0)
check("indisler geçerli", dec.indices.allSatisfy { Int($0) < dec.vertexCount })
check("dejenere üçgen yok", (0..<dec.triangleCount).allSatisfy {
    let a = dec.indices[$0*3], b = dec.indices[$0*3+1], c = dec.indices[$0*3+2]
    return a != b && b != c && a != c
})
check("öksüz vertex yok", {
    let used = Set(dec.indices)
    return used.count == dec.vertexCount
}(), "\(Set(dec.indices).count) / \(dec.vertexCount)")
if let gb = grid.bounds(), let db = dec.bounds() {
    check("sınırlar bir hücre toleransında korundu",
          simd_length(db.size - gb.size) < 0.25, "\(gb.size) -> \(db.size)")
}
check("faceClasses üçgenle senkron", dec.faceClasses.count == dec.triangleCount)
check("cell=0 dokunmuyor", Decimator.decimate(grid, cell: 0).triangleCount == grid.triangleCount)

// MARK: - Duvar hizalama

print("\n[duvar hizalama]")
func rotateZ(_ m: MeshData, _ deg: Float) -> MeshData {
    let r = deg * .pi / 180
    return WallAligner.rotate(m, byYaw: r)
}
let boxZ = box.converted(to: .zUp)
check("hizalı kutuda dönüş ~0", {
    guard let y = WallAligner.dominantYaw(boxZ) else { return false }
    return abs(y) < 0.001
}(), "\(WallAligner.dominantYaw(boxZ).map { $0 * 180 / .pi } ?? -999)")

for angle in [Float(17), 33, -42, 61] {
    let tilted = rotateZ(boxZ, angle)
    guard let yaw = WallAligner.dominantYaw(tilted) else {
        check("\(angle)° için yön bulundu", false); continue
    }
    let straightened = WallAligner.rotate(tilted, byYaw: -yaw)
    let b = straightened.bounds()!
    // 90° periyot: 2x3 m kutu ya 2000x3000 ya 3000x2000 olarak düzelir
    let w = b.size.x * 1000, d = b.size.y * 1000
    let ok = (near(w, 2000, 1) && near(d, 3000, 1)) || (near(w, 3000, 1) && near(d, 2000, 1))
    check("\(angle)° eğik kutu eksenlere oturdu", ok, "\(w) x \(d)")
}

check("yatay düzlemde hizalama yapılmıyor (duvar yok)",
      WallAligner.dominantYaw(grid.converted(to: .zUp)) == nil)

check("pipeline eğikliği düzeltti", {
    var o = ExportOptions()
    o.detail = .raw; o.unit = .millimeters; o.alignToWalls = true
    let tiltedBox = WallAligner.rotate(box.converted(to: .zUp), byYaw: 0.4)
    // converted(to:) tekrar uygulanmasın diye yUp seçemeyiz; zaten zUp olan
    // mesh'i zUp'a çevirmek kimlik dönüşümü değil — bu yüzden ham kutuyu
    // ARKit uzayında döndürüp öyle veriyoruz.
    var arkitTilted = box
    let c = cos(Float(0.4)), s = sin(Float(0.4))
    for i in arkitTilted.positions.indices {
        let p = arkitTilted.positions[i]
        // ARKit Y-yukarı: yatay düzlem XZ
        arkitTilted.positions[i] = SIMD3<Float>(p.x * c - p.z * s, p.y, p.x * s + p.z * c)
    }
    _ = tiltedBox
    let out = MeshPipeline.prepare(mesh: arkitTilted, cloud: CloudSnapshot(), options: o)
    guard out.appliedYawDegrees != nil, let b = out.mesh.bounds() else { return false }
    let w = b.size.x, d = b.size.y
    return (near(w, 2000, 2) && near(d, 3000, 2)) || (near(w, 3000, 2) && near(d, 2000, 2))
}())

check("alignToWalls kapalıyken dokunulmuyor", {
    var o = ExportOptions()
    o.detail = .raw; o.alignToWalls = false
    return MeshPipeline.prepare(mesh: box, cloud: CloudSnapshot(), options: o).appliedYawDegrees == nil
}())

// MARK: - Kesit

print("\n[kesit]")
var opts = ExportOptions()
opts.unit = .millimeters
opts.upAxis = .zUp
opts.detail = .raw
opts.recenterToFloor = true
opts.sectionHeights = [1.2]

let prepared = MeshPipeline.prepare(mesh: box, cloud: CloudSnapshot(), options: opts)
let pb = prepared.mesh.bounds()!
check("mm'ye ölçeklendi", near(pb.size.z, 2500, 0.5), "\(pb.size)")
check("zemin Z=0'da", near(pb.min.z, 0, 0.5), "\(pb.min.z)")
check("XY ortalandı", near(pb.center.x, 0, 0.5) && near(pb.center.y, 0, 0.5), "\(pb.center)")
check("kesit yüksekliği mm'ye çevrildi", near(prepared.sectionHeights[0], 1200, 0.5),
      "\(prepared.sectionHeights[0])")

let segs = SectionSlicer.slice(prepared.mesh, atZ: prepared.sectionHeights[0])
check("kesit parça üretti", !segs.isEmpty, "\(segs.count)")
// 1.2 m'de kesit, kutunun 2000 x 3000 mm dış hattı olmalı
let xs = segs.flatMap { [$0.a.x, $0.b.x] }
let ys = segs.flatMap { [$0.a.y, $0.b.y] }
check("kesit genişliği 2000 mm", near(xs.max()! - xs.min()!, 2000, 1), "\(xs.max()! - xs.min()!)")
check("kesit derinliği 3000 mm", near(ys.max()! - ys.min()!, 3000, 1), "\(ys.max()! - ys.min()!)")
let perimeter = segs.reduce(Float(0)) { $0 + simd_distance($1.a, $1.b) }
check("çevre 2*(2000+3000)=10000 mm", near(perimeter, 10000, 2), "\(perimeter)")

check("tavan üstünde kesit boş", SectionSlicer.slice(prepared.mesh, atZ: 9999).isEmpty)
check("zemin altında kesit boş", SectionSlicer.slice(prepared.mesh, atZ: -9999).isEmpty)
// Düzlem tam vertex hizasındayken çift sayım olmamalı
let atFloor = SectionSlicer.slice(prepared.mesh, atZ: 0)
check("düzlem vertex hizasında patlamıyor", atFloor.count < 100, "\(atFloor.count)")

// MARK: - OBJ

print("\n[OBJ]")
let objData = OBJWriter.data(from: prepared.mesh, unit: .millimeters, name: "test scan")
let objText = String(data: objData, encoding: .utf8)!
let objLines = objText.split(separator: "\n").map(String.init)
check("v satırı sayısı", objLines.filter { $0.hasPrefix("v ") }.count == prepared.mesh.vertexCount)
check("vn satırı sayısı", objLines.filter { $0.hasPrefix("vn ") }.count == prepared.mesh.vertexCount)
check("f satırı sayısı", objLines.filter { $0.hasPrefix("f ") }.count == prepared.mesh.triangleCount)
check("nesne adı temizlendi", objText.contains("o test_scan"))
check("indisler 1 tabanlı ve sınırlar içinde", {
    for line in objLines where line.hasPrefix("f ") {
        for token in line.dropFirst(2).split(separator: " ") {
            guard let i = Int(token.split(separator: "/")[0]) else { return false }
            if i < 1 || i > prepared.mesh.vertexCount { return false }
        }
    }
    return true
}())
check("bilimsel gösterim yok", !objText.lowercased().contains("e-") && !objText.lowercased().contains("e+"))

// MARK: - STL

print("\n[STL]")
let stlData = STLWriter.data(from: prepared.mesh, header: "LidarCAD test unit=mm")
check("boyut = 84 + 50*N", stlData.count == 84 + 50 * prepared.mesh.triangleCount,
      "\(stlData.count) vs \(84 + 50 * prepared.mesh.triangleCount)")
let stlCount = stlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
check("başlıktaki üçgen sayısı", Int(UInt32(littleEndian: stlCount)) == prepared.mesh.triangleCount)
check("ASCII STL sanılmayacak", !stlData.prefix(5).elementsEqual(Array("solid".utf8)))
check("normaller birim uzunlukta", {
    for t in 0..<prepared.mesh.triangleCount {
        let off = 84 + t * 50
        let nx = stlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: Float.self) }
        let ny = stlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 4, as: Float.self) }
        let nz = stlData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: Float.self) }
        if !near(simd_length(SIMD3(nx, ny, nz)), 1, 1e-3) { return false }
    }
    return true
}())

// MARK: - PLY

print("\n[PLY]")
var cloud = CloudSnapshot()
for i in 0..<1000 {
    cloud.positions.append(SIMD3<Float>(Float(i) * 0.001, 0.5, -Float(i) * 0.002))
    cloud.colors.append(SIMD3<UInt8>(UInt8(i % 256), 128, 7))
}
let plyCloud = PLYWriter.data(from: cloud, unit: .meters)
let plyHeaderEnd = plyCloud.range(of: Data("end_header\n".utf8))!.upperBound
let plyHeader = String(data: plyCloud.prefix(plyHeaderEnd), encoding: .utf8)!
check("PLY sihirli bayt", plyHeader.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
check("vertex sayısı bildirildi", plyHeader.contains("element vertex 1000"))
check("gövde boyutu = N*15", plyCloud.count - plyHeaderEnd == 1000 * 15,
      "\(plyCloud.count - plyHeaderEnd)")
check("ilk noktanın rengi doğru", {
    let r = plyCloud[plyHeaderEnd + 12]
    let g = plyCloud[plyHeaderEnd + 13]
    let b = plyCloud[plyHeaderEnd + 14]
    return r == 0 && g == 128 && b == 7
}())

let plyMesh = PLYWriter.data(from: prepared.mesh, unit: .millimeters)
let pmEnd = plyMesh.range(of: Data("end_header\n".utf8))!.upperBound
let pmHeader = String(data: plyMesh.prefix(pmEnd), encoding: .utf8)!
check("mesh PLY vertex sayısı", pmHeader.contains("element vertex \(prepared.mesh.vertexCount)"))
check("mesh PLY face sayısı", pmHeader.contains("element face \(prepared.mesh.triangleCount)"))
check("mesh PLY gövde boyutu",
      plyMesh.count - pmEnd == prepared.mesh.vertexCount * 24 + prepared.mesh.triangleCount * 14,
      "\(plyMesh.count - pmEnd)")

// MARK: - DXF

print("\n[DXF]")
let dxfData = DXFWriter.data(segments: segs, unit: .millimeters)
let dxfText = String(data: dxfData, encoding: .utf8)!
let dxfLines = dxfText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
check("EOF ile bitiyor", dxfText.hasSuffix("0\nEOF\n"))
check("R12 sürüm etiketi", dxfText.contains("$ACADVER\n1\nAC1009"))
check("mm birim kodu ($INSUNITS=4)", dxfText.contains("$INSUNITS\n70\n4"))
check("LINE sayısı kesit parçasıyla eşit",
      dxfLines.filter { $0 == "LINE" }.count == segs.count,
      "\(dxfLines.filter { $0 == "LINE" }.count) vs \(segs.count)")
check("grup kodu/değer çiftleri dengeli", (dxfLines.count - 1) % 2 == 0, "\(dxfLines.count)")
check("her grup kodu tamsayı", {
    var i = 0
    while i + 1 < dxfLines.count - 1 {
        if Int(dxfLines[i]) == nil { return false }
        i += 2
    }
    return true
}())

// MARK: - Uçtan uca export

print("\n[export]")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("lidarcad-verify-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

var fullOpts = ExportOptions()
fullOpts.detail = .raw
fullOpts.formats = Set(ExportFormat.allCases)
fullOpts.sectionHeights = [0.9, 1.2]

let urls = try! ExportManager.write(mesh: box, cloud: cloud, options: fullOpts,
                                    name: "unittest", baseDirectory: tmp)
let names = Set(urls.map { $0.lastPathComponent })
check("OBJ yazıldı", names.contains("unittest.obj"))
check("STL yazıldı", names.contains("unittest.stl"))
check("mesh PLY yazıldı", names.contains("unittest_mesh.ply"))
check("bulut PLY yazıldı", names.contains("unittest_cloud.ply"))
check("iki kesit DXF'i", names.filter { $0.hasSuffix(".dxf") }.count == 2, "\(names)")
check("kesit dosya adı yüksekliği taşıyor", names.contains("unittest_kesit_0_90m.dxf"), "\(names)")
check("OKUBENI yazıldı", names.contains("OKUBENI.txt"))
check("tüm dosyalar boş değil", urls.allSatisfy {
    (try! FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! Int) > 0
})

check("boş format seçimi hata veriyor", {
    var o = ExportOptions(); o.formats = []
    do { _ = try ExportManager.write(mesh: box, cloud: cloud, options: o, name: "x", baseDirectory: tmp); return false }
    catch { return true }
}())
check("boş tarama hata veriyor", {
    do { _ = try ExportManager.write(mesh: MeshData(), cloud: CloudSnapshot(),
                                     options: ExportOptions(), name: "x", baseDirectory: tmp); return false }
    catch { return true }
}())

// MARK: - Nokta bulutu biriktirici

print("\n[nokta bulutu]")
let acc = PointCloudAccumulator(voxelSize: 0.05, maxPoints: 100)
for i in 0..<500 {
    acc.add(SIMD3<Float>(Float(i) * 0.001, 0, 0), color: SIMD3<UInt8>(200, 100, 50))
}
check("aynı voxel'e düşenler birleşti", acc.count <= 10, "\(acc.count)")
let snap = acc.snapshot()
check("anlık görüntü tutarlı", snap.positions.count == acc.count && snap.colors.count == acc.count)
check("renk ortalaması korundu", snap.colors.allSatisfy { $0 == SIMD3<UInt8>(200, 100, 50) })
for i in 0..<5000 { acc.add(SIMD3<Float>(Float(i) * 10, 0, 0), color: SIMD3<UInt8>(1, 2, 3)) }
check("maxPoints tavanı uygulandı", acc.count <= 100, "\(acc.count)")
check("doygunluk bayrağı", acc.isSaturated)
acc.reset()
check("reset temizledi", acc.count == 0 && !acc.isSaturated)

print("\n\(checks - failures)/\(checks) geçti")
if failures > 0 { print("\(failures) BAŞARISIZ"); exit(1) }
print("hepsi tamam")
