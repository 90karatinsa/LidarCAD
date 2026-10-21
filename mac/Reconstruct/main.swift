import Foundation
import RealityKit

// lidarcad-reconstruct — iPhone'daki "Fotoğraf seti" klasöründen CAD'e hazır model.
//
// iOS'taki fotogrametri yalnızca .reduced detay veriyor; Mac'te .full / .raw
// var. Çıkan mesh telefondaki export hattının aynısından geçiyor.

let usage = """
Kullanım: lidarcad-reconstruct <fotoğraf-klasörü> [seçenekler]

  --out KLASÖR       Çıktı klasörü (varsayılan: <klasör>-model)
  --detail SEVİYE    preview | reduced | medium | full | raw   (varsayılan: full)
  --mask KİP         auto | vision | none   (varsayılan: auto)
                       auto:   Apple'ın kendi nesne maskelemesi. Döner tabla testlerinin
                               hepsinde, dağınık arka planda da en doğru sonuç buydu.
                       vision: her fotoğrafa Vision ile maske; nesnenin ayrılamadığı
                               fotoğraflar atlanır. Düz arka planda kamera dolaşırken işe yarar.
  --sensitive        Az dokulu nesneler için yüksek özellik hassasiyeti (daha yavaş)
  --decimate SEVİYE  raw | fine | medium | coarse   (varsayılan: fine)
  --unit BİRİM       mm | cm | m   (varsayılan: mm)
  --formats LİSTE    obj,stl,plymesh,dxf   (varsayılan: obj,stl)
  --sections LİSTE   DXF kesit yükseklikleri, metre, virgülle: 0.02,0.05
  --name AD          Dosya adı (varsayılan: klasör adı)
"""

enum MaskMode: String { case vision, auto, none }

struct Arguments {
    var input: URL
    var output: URL?
    var detail: PhotogrammetrySession.Request.Detail = .full
    var mask: MaskMode = .auto
    var sensitive = false
    var decimate: DetailLevel = .fine
    var unit: LengthUnit = .millimeters
    var formats: Set<ExportFormat> = [.obj, .stl]
    var sections: [Float] = []
    var name: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hata: \(message)\n".utf8))
    exit(1)
}

func parseArguments() -> Arguments {
    var rest = Array(CommandLine.arguments.dropFirst())
    if rest.isEmpty || rest.contains("-h") || rest.contains("--help") {
        print(usage); exit(rest.isEmpty ? 1 : 0)
    }
    var args = Arguments(input: URL(fileURLWithPath: (rest.removeFirst() as NSString).expandingTildeInPath))

    func value(_ flag: String) -> String {
        guard !rest.isEmpty else { fail("\(flag) bir değer bekliyor") }
        return rest.removeFirst()
    }

    while !rest.isEmpty {
        let flag = rest.removeFirst()
        switch flag {
        case "--out":
            args.output = URL(fileURLWithPath: (value(flag) as NSString).expandingTildeInPath)
        case "--detail":
            let v = value(flag)
            let map: [String: PhotogrammetrySession.Request.Detail] =
                ["preview": .preview, "reduced": .reduced, "medium": .medium, "full": .full, "raw": .raw]
            guard let d = map[v] else { fail("bilinmeyen detay: \(v)") }
            args.detail = d
        case "--mask":
            let v = value(flag)
            guard let m = MaskMode(rawValue: v) else { fail("bilinmeyen maske kipi: \(v)") }
            args.mask = m
        case "--sensitive":
            args.sensitive = true
        case "--decimate":
            let v = value(flag)
            guard let d = DetailLevel(rawValue: v) else { fail("bilinmeyen sadeleştirme: \(v)") }
            args.decimate = d
        case "--unit":
            let v = value(flag)
            let map: [String: LengthUnit] = ["mm": .millimeters, "cm": .centimeters, "m": .meters]
            guard let u = map[v] else { fail("bilinmeyen birim: \(v)") }
            args.unit = u
        case "--formats":
            let map: [String: ExportFormat] = ["obj": .obj, "stl": .stl, "plymesh": .plyMesh, "dxf": .dxf]
            var set = Set<ExportFormat>()
            for item in value(flag).split(separator: ",") {
                guard let f = map[String(item)] else { fail("bilinmeyen format: \(item)") }
                set.insert(f)
            }
            args.formats = set
        case "--sections":
            args.sections = value(flag).split(separator: ",").compactMap { Float($0) }
        case "--name":
            args.name = value(flag)
        default:
            fail("bilinmeyen seçenek: \(flag)\n\n\(usage)")
        }
    }
    if !args.sections.isEmpty { args.formats.insert(.dxf) }
    return args
}

// MARK: - Girdi

let args = parseArguments()

/// iPhone seti AirDrop'a tek dosya olsun diye zip'liyor; zip verilirse
/// geçici bir klasöre açıp içindeki capture.json'lı klasörü kullanıyoruz.
func resolveInput(_ url: URL) -> URL {
    guard url.pathExtension.lowercased() == "zip" else { return url }
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lidarcad-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", url.path, temp.path]
    do { try ditto.run(); ditto.waitUntilExit() } catch { fail("zip açılamadı: \(error.localizedDescription)") }
    guard ditto.terminationStatus == 0 else { fail("zip açılamadı: \(url.lastPathComponent)") }
    let enumerator = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil)
    while let item = enumerator?.nextObject() as? URL {
        if item.lastPathComponent == CaptureManifest.fileName { return item.deletingLastPathComponent() }
    }
    return temp
}

let folder = resolveInput(args.input)
let inputStem = args.input.deletingPathExtension().lastPathComponent
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("klasör bulunamadı: \(folder.path)")
}
guard PhotogrammetrySession.isSupported else {
    fail("bu Mac fotogrametriyi desteklemiyor (Apple Silicon ya da yeterli GPU gerekir)")
}

let manifest = try? CaptureManifest.load(from: folder)
let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

var entries: [LazySampleSequence.Entry] = []
if let manifest {
    for (i, shot) in manifest.shots.enumerated() {
        let url = folder.appendingPathComponent(shot.file)
        if FileManager.default.fileExists(atPath: url.path) {
            entries.append(.init(id: i, url: url, shot: shot))
        }
    }
} else {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    entries = images.enumerated().map { .init(id: $0.offset, url: $0.element, shot: nil) }
}
guard entries.count >= 3 else { fail("en az 3 fotoğraf gerekiyor, bulunan: \(entries.count)") }

let useGravity = manifest?.gravityIsConsistent ?? false
let name = args.name ?? inputStem
// Zip verildiyse çıktı geçici klasöre değil, zip'in yanına gitsin.
let output = args.output ?? args.input.deletingLastPathComponent()
    .appendingPathComponent(inputStem + "-model", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

print("""
Fotoğraf    : \(entries.count)\(manifest.map { "  (\($0.passCount) tur)" } ?? "")
Derinlik    : \(manifest.map { $0.shots.allSatisfy(\.hasDepth) ? "var (ölçek LiDAR'dan)" : "eksik — ölçek tahmini olur" } ?? "bilinmiyor")
Yerçekimi   : \(useGravity ? "kullanılıyor" : "kullanılmıyor\(manifest.map { $0.passCount > 1 ? " (nesne çevrilmiş)" : "" } ?? "")")
Maske       : \(args.mask.rawValue)
Detay       : \(args.detail)
Çıktı       : \(output.path)

""")

// MARK: - Fotogrametri

var configuration = PhotogrammetrySession.Configuration()
configuration.isObjectMaskingEnabled = args.mask != .none
configuration.sampleOrdering = .sequential
configuration.featureSensitivity = args.sensitive ? .high : .normal
configuration.checkpointDirectory = output.appendingPathComponent("checkpoint", isDirectory: true)

var loaded = 0
var maskMisses = 0
let session: PhotogrammetrySession
do {
    // Her kipte örnek dizisi: derinlik ve (tek turlu setlerde) yerçekimi
    // açıkça gidiyor. auto/none'da maskeyi Apple'ın oturumu kendisi yapıyor.
    switch args.mask {
    case .vision, .auto, .none:
        let samples = LazySampleSequence(entries: entries, useMask: args.mask == .vision,
                                         useGravity: useGravity) { entry, sample, error in
            loaded += 1
            if let error {
                print("\r  uyarı: \(entry.url.lastPathComponent) atlandı — \(error.localizedDescription)")
            } else if sample == nil {
                maskMisses += 1
            }
        }
        session = try PhotogrammetrySession(input: samples, configuration: configuration)
    }
} catch {
    fail("fotogrametri oturumu açılamadı: \(error.localizedDescription)")
}

let modelURL = output.appendingPathComponent("\(name).usdz")
do {
    try session.process(requests: [.modelFile(url: modelURL, detail: args.detail)])
} catch {
    fail("işlem başlatılamadı: \(error.localizedDescription)")
}

let started = Date()
var invalid = 0
var lastPercent = -1
do {
    outputLoop: for try await event in session.outputs {
        switch event {
        case .inputComplete:
            print("\r  girdi okundu (\(entries.count - invalid - maskMisses) fotoğraf kullanıldı)\(maskMisses > 0 ? ", \(maskMisses) tanesi nesne ayrılamadığı için atlandı" : "")")
        case .invalidSample(let id, let reason):
            invalid += 1
            let file = entries.first { $0.id == id }?.url.lastPathComponent ?? "#\(id)"
            print("\r  geçersiz fotoğraf: \(file) — \(reason)")
        case .requestProgress(_, let fraction):
            let percent = Int(fraction * 100)
            if percent != lastPercent {
                lastPercent = percent
                let elapsed = Int(Date().timeIntervalSince(started))
                print("\r  model oluşturuluyor: %\(percent)  (\(elapsed / 60) dk \(elapsed % 60) sn)", terminator: "")
                fflush(stdout)
            }
        case .requestComplete(_, let result):
            if case .modelFile(let url) = result { print("\r  model yazıldı: \(url.lastPathComponent)            ") }
        case .requestError(_, let error):
            fail("model oluşturulamadı: \(error.localizedDescription)")
        case .processingCancelled:
            fail("işlem iptal edildi")
        case .processingComplete:
            break outputLoop
        default:
            break
        }
    }
} catch {
    fail("fotogrametri hatası: \(error.localizedDescription)")
}

// MARK: - CAD export

let mesh: MeshData
do {
    mesh = try MeshLoader.load(modelURL)
} catch {
    fail("model okunamadı: \(error.localizedDescription)")
}

var options = ScanKind.object.defaultOptions
options.unit = args.unit
options.detail = args.decimate
options.formats = args.formats
options.sectionHeights = args.sections

do {
    let files = try ExportManager.write(mesh: mesh, cloud: CloudSnapshot(), options: options,
                                        name: name, exactDirectory: output)
    let minutes = Int(Date().timeIntervalSince(started)) / 60
    print("\nTamam — \(minutes) dk. Model \(mesh.triangleCount) üçgen.\n")
    print("  \(modelURL.lastPathComponent)  (dokulu, önizleme için)")
    for url in files { print("  \(url.lastPathComponent)") }
    print("\nKlasör: \(output.path)")
} catch {
    fail("dosyalar yazılamadı: \(error.localizedDescription)")
}
