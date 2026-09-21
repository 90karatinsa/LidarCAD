import ARKit
import CoreVideo
import simd

/// LiDAR derinlik haritasını dünya uzayı renkli noktalara açar.
///
/// Rekonstrüksiyon mesh'i ARKit tarafından güçlü şekilde düzleştirilmiş olarak
/// gelir; ham derinlik haritası daha gürültülü ama daha keskin. Ölçü almak ve
/// CloudCompare'de kesit çıkarmak için nokta bulutu mesh'ten daha faydalı.
enum DepthUnprojector {

    /// - Parameters:
    ///   - pixelStride: derinlik haritasında kaç pikselde bir örnek alınacağı.
    ///   - maxDepth: metre. LiDAR ~5 m'den sonra güvenilmez.
    static func accumulate(frame: ARFrame,
                           into cloud: PointCloudAccumulator,
                           pixelStride: Int = 2,
                           minConfidence: UInt8 = 2,
                           maxDepth: Float = 5.0,
                           minDepth: Float = 0.15) {

        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthMap = sceneDepth.depthMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        let confidenceMap = sceneDepth.confidenceMap
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        // Renk düzlemi (420 YCbCr, full range)
        let image = frame.capturedImage
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let hasColor = lumaBase != nil && chromaBase != nil

        // Intrinsics tam çözünürlük için verilir; derinlik haritası ölçeğine indir.
        let resolution = frame.camera.imageResolution
        let scaleX = Float(depthWidth) / Float(resolution.width)
        let scaleY = Float(depthHeight) / Float(resolution.height)
        let K = frame.camera.intrinsics
        let fx = K[0][0] * scaleX
        let fy = K[1][1] * scaleY
        let cx = K[2][0] * scaleX
        let cy = K[2][1] * scaleY
        guard fx != 0, fy != 0 else { return }

        let cameraToWorld = frame.camera.transform
        let lumaScaleX = Float(lumaWidth) / Float(depthWidth)
        let lumaScaleY = Float(lumaHeight) / Float(depthHeight)

        var v = 0
        while v < depthHeight {
            let depthRow = depthBase.advanced(by: v * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: v * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)

            var u = 0
            while u < depthWidth {
                defer { u += pixelStride }

                let depth = depthRow[u]
                guard depth > minDepth, depth < maxDepth, depth.isFinite else { continue }
                if let confidenceRow, confidenceRow[u] < minConfidence { continue }

                // Görüntü y ekseni aşağı, kamera y ekseni yukarı; kamera -Z'ye bakar.
                let x = (Float(u) - cx) * depth / fx
                let y = (Float(v) - cy) * depth / fy
                let world = cameraToWorld * SIMD4<Float>(x, -y, -depth, 1)

                var color = SIMD3<UInt8>(180, 180, 180)
                if hasColor {
                    let lu = min(lumaWidth - 1, Int(Float(u) * lumaScaleX))
                    let lv = min(lumaHeight - 1, Int(Float(v) * lumaScaleY))
                    let luma = Float(lumaBase!.advanced(by: lv * lumaRowBytes + lu)
                        .assumingMemoryBound(to: UInt8.self).pointee)

                    let cu = min(chromaWidth - 1, lu / 2)
                    let cv = min(chromaHeight - 1, lv / 2)
                    let chroma = chromaBase!.advanced(by: cv * chromaRowBytes + cu * 2)
                        .assumingMemoryBound(to: UInt8.self)
                    let cb = Float(chroma[0]) - 128
                    let cr = Float(chroma[1]) - 128

                    color = SIMD3<UInt8>(
                        clamp8(luma + 1.402 * cr),
                        clamp8(luma - 0.344136 * cb - 0.714136 * cr),
                        clamp8(luma + 1.772 * cb))
                }

                cloud.add(world.xyz, color: color)
            }
            v += pixelStride
        }
    }

    @inline(__always)
    private static func clamp8(_ value: Float) -> UInt8 {
        if value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value)
    }
}
