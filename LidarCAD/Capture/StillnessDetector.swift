import CoreVideo
import QuartzCore

/// Kameradaki hareketi izler ve "nesne çevrildi, el çekildi, sahne durdu"
/// anını yakalar. Döner tabla çekiminde deklanşöre dokunmak telefonu
/// sarsar ve eli kadraja sokar; bunun yerine sahne durulunca çekiyoruz.
///
/// Yalnızca analiz kuyruğunda kullanılır.
final class StillnessDetector: @unchecked Sendable {

    enum Event: Equatable {
        case moving
        /// Durulma ilerlemesi, 0...1.
        case settling(Double)
        /// Çekim zamanı. Bir sonraki çekim için önce yeniden hareket görülmeli.
        case still
        case idle
    }

    /// Ortalama mutlak parlaklık farkı (0–255). Kamera sabitken sensör
    /// gürültüsü ~1, el kadraja girince 10+.
    var motionThreshold: Float = 5
    var stillThreshold: Float = 1.8
    var stillDuration: CFTimeInterval = 0.8

    private let gridWidth = 64
    private let gridHeight = 48
    private var previous: [UInt8] = []
    private var stillSince: CFTimeInterval?
    /// Son çekimden beri hareket görüldü mü. Görülmediyse aynı kareyi tekrar
    /// tekrar çekmeyelim.
    private var armed = true

    func reset() {
        previous.removeAll()
        stillSince = nil
        armed = true
    }

    /// Manuel çekimden sonra: otomatik deklanşör hemen ikinci kez basmasın.
    func disarm() {
        armed = false
        stillSince = nil
    }

    func process(_ buffer: CVPixelBuffer, now: CFTimeInterval = CACurrentMediaTime()) -> Event {
        guard let current = sampleLuma(buffer) else { return .idle }
        defer { previous = current }
        guard previous.count == current.count else { return .idle }

        var total = 0
        for i in 0..<current.count {
            total += abs(Int(current[i]) - Int(previous[i]))
        }
        let difference = Float(total) / Float(current.count)

        if difference > motionThreshold {
            stillSince = nil
            armed = true
            return .moving
        }
        guard difference < stillThreshold, armed else {
            stillSince = nil
            return .idle
        }
        if stillSince == nil { stillSince = now }
        let elapsed = now - (stillSince ?? now)
        if elapsed >= stillDuration {
            armed = false
            stillSince = nil
            return .still
        }
        return .settling(min(1, elapsed / stillDuration))
    }

    /// 420 biplanar karenin parlaklık düzleminden seyrek bir ızgara örnekler.
    private func sampleLuma(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        var out = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let y = (gy * height) / gridHeight + height / (gridHeight * 2)
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for gx in 0..<gridWidth {
                let x = (gx * width) / gridWidth + width / (gridWidth * 2)
                out[gy * gridWidth + gx] = row[x]
            }
        }
        return out
    }
}
