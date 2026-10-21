// Mac aracının fotogrametri dışındaki parçalarını sınar:
// HEIC'e gömülü derinliği okuma (ölçek buradan gelir) ve USDZ → MeshData.
import Foundation
import AVFoundation
import ImageIO
import ModelIO
import UniformTypeIdentifiers
import simd

var failures = 0, checks = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)  -> \(detail())") }
}
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lidarcad-mac-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: - Derinlik gömülü HEIC

print("\n[HEIC derinliği]")
let imgW = 640, imgH = 480, depthW = 320, depthH = 240
let ctx = CGContext(data: nil, width: imgW, height: imgH, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
let image = ctx.makeImage()!

// Sol yarı 0,30 m, sağ yarı 0,55 m: okumada sıra/yön karışırsa yakalansın.
var depthValues = [Float32](repeating: 0, count: depthW * depthH)
for y in 0..<depthH { for x in 0..<depthW { depthValues[y * depthW + x] = x < depthW / 2 ? 0.30 : 0.55 } }
let depthDict: [AnyHashable: Any] = [
    kCGImageAuxiliaryDataInfoData: Data(bytes: depthValues, count: depthValues.count * 4) as CFData,
    kCGImageAuxiliaryDataInfoDataDescription: [
        kCGImagePropertyPixelFormat: kCVPixelFormatType_DepthFloat32,
        kCGImagePropertyWidth: depthW, kCGImagePropertyHeight: depthH,
        kCGImagePropertyBytesPerRow: depthW * 4,
    ] as CFDictionary,
]
let depthData = try! AVDepthData(fromDictionaryRepresentation: depthDict)
let heic = tmp.appendingPathComponent("IMG_0001.HEIC")
let dest = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
var auxType: NSString?
let aux = depthData.dictionaryRepresentation(forAuxiliaryDataType: &auxType)!
CGImageDestinationAddAuxiliaryDataInfo(dest, auxType! as CFString, aux as CFDictionary)
check("HEIC yazıldı", CGImageDestinationFinalize(dest))

let (loaded, props) = try! SampleFactory.loadImage(heic)
check("görüntü boyutu korunuyor", CVPixelBufferGetWidth(loaded) == imgW && CVPixelBufferGetHeight(loaded) == imgH,
      "\(CVPixelBufferGetWidth(loaded))x\(CVPixelBufferGetHeight(loaded))")
check("görüntü BGRA", CVPixelBufferGetPixelFormatType(loaded) == kCVPixelFormatType_32BGRA)
check("metadata okundu", !props.isEmpty)

if let depth = SampleFactory.loadDepth(heic) {
    check("derinlik bulundu", true)
    check("derinlik DepthFloat32", CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32)
    check("derinlik boyutu", CVPixelBufferGetWidth(depth) == depthW && CVPixelBufferGetHeight(depth) == depthH,
          "\(CVPixelBufferGetWidth(depth))x\(CVPixelBufferGetHeight(depth))")
    CVPixelBufferLockBaseAddress(depth, .readOnly)
    let row = CVPixelBufferGetBytesPerRow(depth)
    let base = CVPixelBufferGetBaseAddress(depth)!
    func at(_ x: Int, _ y: Int) -> Float { base.advanced(by: y * row + x * 4).assumingMemoryBound(to: Float32.self).pointee }
    let left = at(depthW / 4, depthH / 2), right = at(3 * depthW / 4, depthH / 2)
    CVPixelBufferUnlockBaseAddress(depth, .readOnly)
    check("sol yarı 0,30 m", abs(left - 0.30) < 0.002, "\(left)")
    check("sağ yarı 0,55 m", abs(right - 0.55) < 0.002, "\(right)")
} else {
    check("derinlik bulundu", false, "loadDepth nil döndü")
}

let plain = tmp.appendingPathComponent("plain.jpg")
let d2 = CGImageDestinationCreateWithURL(plain as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d2, image, nil); CGImageDestinationFinalize(d2)
check("derinliksiz dosyada nil", SampleFactory.loadDepth(plain) == nil)

// MARK: - USDZ → MeshData

print("\n[USD okuma]")
// ModelIO .usdz'yi okuyabiliyor ama yazamıyor; gidiş-dönüş için aynı USD
// içeriğinin ikili biçimi .usdc kullanılıyor. Okuyucu .usdz'yi uçtan uca
// koşularda fotogrametri çıktısından zaten okuyor.
check("USD (usdc) dışa aktarılabiliyor", MDLAsset.canExportFileExtension("usdc"))
let allocator = MDLMeshBufferDataAllocator()
// 0,10 x 0,06 x 0,04 m kutu, (0,2 , 0 , 0) konumunda — dönüşüm uygulanıyor mu?
let boxMesh = MDLMesh(boxWithExtent: SIMD3(0.10, 0.06, 0.04), segments: SIMD3(1, 1, 1),
                      inwardNormals: false, geometryType: .triangles, allocator: allocator)
boxMesh.transform = MDLTransform(matrix: simd_float4x4(translation: SIMD3(0.2, 0, 0)))
let asset = MDLAsset(); asset.add(boxMesh)
let usdz = tmp.appendingPathComponent("box.usdc")
do { try asset.export(to: usdz) } catch { check("USDZ yazıldı", false, "\(error)") }

if let mesh = try? MeshLoader.load(usdz) {
    check("üçgen var", mesh.triangleCount == 12, "\(mesh.triangleCount)")
    check("indisler geçerli", mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
    check("normaller vertex sayısında", mesh.normals.count == mesh.vertexCount)
    let b = mesh.bounds()!
    check("boyut 10 x 6 x 4 cm", simd_length(b.size - SIMD3(0.10, 0.06, 0.04)) < 1e-4, "\(b.size)")
    check("yerleşim dönüşümü uygulandı", abs(b.center.x - 0.2) < 1e-4, "\(b.center)")
} else {
    check("USDZ okundu", false, "MeshLoader hata verdi")
}

print("\n\(checks - failures)/\(checks) geçti")
exit(failures == 0 ? 0 : 1)

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }
}
