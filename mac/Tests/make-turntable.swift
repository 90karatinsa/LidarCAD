// Döner tabla senaryosunu sentetik olarak üretir: kamera ve ışık sabit,
// dokulu bir kutu kendi ekseni etrafında döner, arka plan düz gri.
// lidarcad-reconstruct'ı gerçek çekim olmadan uçtan uca sınamak için.
//
//   swiftc -O -o /tmp/make-turntable mac/Tests/make-turntable.swift && /tmp/make-turntable <çıktı-klasörü>
import Foundation
import SceneKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Tekrarlanabilir doku için tohumlu üreteç.
struct XorShift: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

func makeTexture(seed: UInt64) -> CGImage {
    var rng = XorShift(state: seed)
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.85, green: 0.8, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // Fotogrametri eşsiz özellik ister: farklı boyut/renkte yüzlerce leke.
    for _ in 0..<900 {
        let r = CGFloat(Double.random(in: 0.05...0.95, using: &rng))
        let g = CGFloat(Double.random(in: 0.05...0.95, using: &rng))
        let b = CGFloat(Double.random(in: 0.05...0.95, using: &rng))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        let w = CGFloat(Double.random(in: 6...60, using: &rng))
        let h = CGFloat(Double.random(in: 6...60, using: &rng))
        let x = CGFloat(Double.random(in: 0...Double(size), using: &rng))
        let y = CGFloat(Double.random(in: 0...Double(size), using: &rng))
        if Bool.random(using: &rng) {
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        } else {
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
    }
    return ctx.makeImage()!
}

let argv = CommandLine.arguments
let outDir = URL(fileURLWithPath: argv.count > 1 ? argv[1] : "turntable")
/// --orbit: nesne sabit, kamera dolaşır (fotogrametrinin standart senaryosu).
let orbit = argv.contains("--orbit")
/// --soft: döner tabla stüdyosundaki gibi dağınık ışık; gölge açıyla değişmez.
let soft = argv.contains("--soft")
/// --clutter: nesnenin arkasında sabit, dokulu bir duvar — gerçek bir masa/oda
/// arka planı. Döner tablada en zor durum: arka plan "kamera kıpırdamadı" der.
let clutter = argv.contains("--clutter")
let distanceArg = argv.firstIndex(of: "--distance").flatMap { argv.count > $0 + 1 ? Double(argv[$0 + 1]) : nil }
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let scene = SCNScene()
scene.background.contents = NSColor(white: 0.55, alpha: 1)

// 10 x 6 x 4 cm kutu (SceneKit birimi metre).
let box = SCNBox(width: 0.10, height: 0.06, length: 0.04, chamferRadius: 0.002)
box.materials = (0..<6).map { face in
    let m = SCNMaterial()
    m.diffuse.contents = makeTexture(seed: 0x9E3779B97F4A7C15 &+ UInt64(face) &* 7919)
    m.lightingModel = .physicallyBased
    m.roughness.contents = 0.8
    return m
}
let object = SCNNode(geometry: box)
scene.rootNode.addChildNode(object)

if clutter {
    let wall = SCNPlane(width: 1.2, height: 0.9)
    let m = SCNMaterial()
    m.diffuse.contents = makeTexture(seed: 0xC0FFEE)
    m.lightingModel = .physicallyBased
    m.roughness.contents = 0.9
    wall.materials = [m]
    let wallNode = SCNNode(geometry: wall)
    wallNode.position = SCNVector3(0, 0.1, -0.45)
    scene.rootNode.addChildNode(wallNode)
}

// Işık ve kamera sabit — gerçek döner tablada olduğu gibi.
let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional
key.light!.intensity = soft ? 150 : 900
key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
scene.rootNode.addChildNode(key)
let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .ambient
fill.light!.intensity = soft ? 1100 : 450
scene.rootNode.addChildNode(fill)

let camera = SCNNode()
camera.camera = SCNCamera()
camera.camera!.fieldOfView = 55
camera.camera!.zNear = 0.01
scene.rootNode.addChildNode(camera)

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal yok") }
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = camera

// İki halka: alçak ve yüksek bakış açısı; nesne her karede döner.
let rings: [(elevation: Double, count: Int)] = [(18, 36), (42, 24)]
var index = 0
for ring in rings {
    let el = ring.elevation * .pi / 180
    let distance = distanceArg ?? 0.32
    for step in 0..<ring.count {
        let angle = Double(step) / Double(ring.count) * 2 * .pi
        if orbit {
            // Kamera nesnenin etrafında döner; nesne ve ışık sabit.
            camera.position = SCNVector3(CGFloat(distance * cos(el) * sin(angle)),
                                         CGFloat(distance * sin(el)),
                                         CGFloat(distance * cos(el) * cos(angle)))
        } else {
            camera.position = SCNVector3(0, CGFloat(distance * sin(el)), CGFloat(distance * cos(el)))
            object.eulerAngles.y = CGFloat(angle)
        }
        camera.look(at: SCNVector3(0, 0, 0))
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1920, height: 1440), antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        index += 1
        let url = outDir.appendingPathComponent(String(format: "IMG_%04d.JPG", index))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        // Kamera iç parametreleri için EXIF odak uzaklığı (iPhone ana kamera ~26 mm eşdeğer).
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFocalLength: 6.765,
                                             kCGImagePropertyExifFocalLenIn35mmFilm: 26],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic",
                                             kCGImagePropertyTIFFModel: "Turntable"],
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
print("\(index) kare yazıldı (\(orbit ? "kamera dolaşıyor" : "döner tabla"), \(soft ? "yumuşak" : "sert") ışık\(clutter ? ", dokulu arka plan" : "")): \(outDir.path)")
