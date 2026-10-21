import Foundation
import CoreImage
import CoreVideo
import CoreMotion
import ImageIO
import AVFoundation
import Vision
import RealityKit

/// iPhone'un çektiği HEIC'leri `PhotogrammetrySample`'a çevirir.
///
/// Döner tablada kamera sabit, nesne döner. Arka plan bütün fotoğraflarda
/// aynı yerde durduğu için fotogrametriye "kamera hiç kıpırdamadı" der ve
/// nesnenin söylediğiyle çelişir. Bu yüzden her fotoğrafa nesne maskesi
/// veriyoruz: arka plan hesaba hiç girmesin.
enum SampleFactory {

    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) okunamadı"
            }
        }
    }

    // MARK: - Görüntü

    /// Ham sensör yönünde BGRA. EXIF yönünü uygulamıyoruz: derinlik haritası
    /// ve maske de aynı yönde, döndürürsek birbirinden kopar. Yön bilgisi
    /// metadata ile fotogrametriye ayrıca gidiyor.
    static func loadImage(_ url: URL) throws -> (CVPixelBuffer, [String: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]

        let width = cgImage.width, height = cgImage.height
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        guard let buffer else { throw Failure.unreadable(url.lastPathComponent) }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw Failure.unreadable(url.lastPathComponent) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, properties)
    }

    // MARK: - Derinlik

    /// HEIC'e gömülü LiDAR derinliği, metre, DepthFloat32. Ölçek buradan
    /// geliyor — yoksa model doğru şekilde ama keyfi boyutta çıkar.
    static func loadDepth(_ url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let info = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)
                    ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity))
                    as? [AnyHashable: Any]
        guard let info, var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        if depth.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        return depth.depthDataMap
    }

    // MARK: - Nesne maskesi

    /// Vision'ın ön plan ayırıcısıyla nesne maskesi, OneComponent8, görüntüyle
    /// aynı boyut. Birden fazla ön plan nesnesi varsa (nesne + kadraja giren
    /// el gibi) görüntünün merkezindekini seçiyoruz.
    static func makeMask(for image: CVPixelBuffer) throws -> CVPixelBuffer? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }

        let chosen = centerInstance(in: observation) ?? observation.allInstances
        let scaled = try observation.generateScaledMaskForImage(forInstances: chosen, from: handler)
        return toOneComponent8(scaled)
    }

    private static func centerInstance(in observation: VNInstanceMaskObservation) -> IndexSet? {
        let labels = observation.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        let row = CVPixelBufferGetBytesPerRow(labels)
        // Merkezde 5x5'lik bir pencerede en sık geçen etiket — tam merkez
        // pikseli nesnenin bir deliğine denk gelebilir.
        var votes: [UInt8: Int] = [:]
        for dy in -2...2 {
            for dx in -2...2 {
                let x = min(max(w / 2 + dx * w / 40, 0), w - 1)
                let y = min(max(h / 2 + dy * h / 40, 0), h - 1)
                let label = base.advanced(by: y * row + x).assumingMemoryBound(to: UInt8.self).pointee
                if label != 0 { votes[label, default: 0] += 1 }
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value })?.key else { return nil }
        return IndexSet(integer: Int(best))
    }

    private static func toOneComponent8(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_OneComponent8 { return source }

        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard let out else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(out) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(source), dstRow = CVPixelBufferGetBytesPerRow(out)

        for y in 0..<h {
            let d = dst.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
            switch format {
            case kCVPixelFormatType_OneComponent32Float:
                let s = src.advanced(by: y * srcRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<w { d[x] = UInt8(clamping: Int((min(max(s[x], 0), 1) * 255).rounded())) }
            case kCVPixelFormatType_OneComponent16Half:
                let s = src.advanced(by: y * srcRow).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { d[x] = UInt8(clamping: Int((min(max(Float(s[x]), 0), 1) * 255).rounded())) }
            default:
                return nil
            }
        }
        return out
    }

    // MARK: - Örnek

    /// - Returns: Maske istenip nesne ayrılamadıysa `nil`. Maskeli ve maskesiz
    ///   fotoğrafı karıştırmak en kötü seçenek: maskesizlerdeki sabit arka plan
    ///   modeli bozar (sentetik testte %49 sapma). O fotoğrafı atlamak daha iyi.
    static func sample(id: Int,
                       url: URL,
                       shot: CaptureManifest.Shot?,
                       useMask: Bool,
                       useGravity: Bool) throws -> PhotogrammetrySample? {
        let (image, properties) = try loadImage(url)
        var sample = PhotogrammetrySample(id: id, image: image)
        // Odak uzaklığı, sensör boyutu, yön: kamera iç parametreleri buradan.
        sample.metadata = properties
        if let depth = loadDepth(url) { sample.depthDataMap = depth }
        if useMask {
            guard let mask = try makeMask(for: image) else { return nil }
            sample.objectMask = mask
        }
        if useGravity, let g = shot?.gravity, g.count == 3 {
            sample.gravity = CMAcceleration(x: g[0], y: g[1], z: g[2])
        }
        return sample
    }
}

/// Fotoğrafları ihtiyaç anında yükleyen dizi. 80 adet 12 MP fotoğrafı BGRA
/// olarak bir anda belleğe almak ~4 GB eder; teker teker okuyoruz.
struct LazySampleSequence: Sequence {
    struct Entry {
        var id: Int
        var url: URL
        var shot: CaptureManifest.Shot?
    }

    let entries: [Entry]
    let useMask: Bool
    let useGravity: Bool
    let onLoad: (Entry, PhotogrammetrySample?, Error?) -> Void

    func makeIterator() -> Iterator { Iterator(sequence: self) }

    struct Iterator: IteratorProtocol {
        let sequence: LazySampleSequence
        var index = 0

        mutating func next() -> PhotogrammetrySample? {
            while index < sequence.entries.count {
                let entry = sequence.entries[index]
                index += 1
                do {
                    let sample = try SampleFactory.sample(id: entry.id, url: entry.url, shot: entry.shot,
                                                          useMask: sequence.useMask,
                                                          useGravity: sequence.useGravity)
                    sequence.onLoad(entry, sample, nil)
                    if let sample { return sample }
                } catch {
                    sequence.onLoad(entry, nil, error)
                }
            }
            return nil
        }
    }
}
