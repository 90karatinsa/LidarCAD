import Foundation
import simd

/// Voxel-hashed nokta bulutu biriktirici.
///
/// Her karede ~12k nokta geliyor; ham biriktirmek dakikalar içinde belleği
/// doldurur. Aynı voxel'e düşen noktalar ortalanır: hem bellek sabit kalır
/// hem de tekrar tekrar taranan yüzeylerdeki gürültü azalır.
final class PointCloudAccumulator {

    private struct Cell {
        var position: SIMD3<Double>
        var color: SIMD3<Double>
        var count: Double
    }

    private var cells: [SIMD3<Int32>: Cell] = [:]
    private let inverseVoxel: Float

    let voxelSize: Float
    let maxPoints: Int

    private(set) var isSaturated = false

    init(voxelSize: Float = 0.01, maxPoints: Int = 4_000_000) {
        self.voxelSize = voxelSize
        self.inverseVoxel = 1 / voxelSize
        self.maxPoints = maxPoints
        cells.reserveCapacity(200_000)
    }

    var count: Int { cells.count }

    func add(_ p: SIMD3<Float>, color: SIMD3<UInt8>) {
        let key = SIMD3<Int32>(
            Int32((p.x * inverseVoxel).rounded(.down)),
            Int32((p.y * inverseVoxel).rounded(.down)),
            Int32((p.z * inverseVoxel).rounded(.down))
        )
        let c = SIMD3<Double>(Double(color.x), Double(color.y), Double(color.z))

        if let existing = cells[key] {
            cells[key] = Cell(position: existing.position + SIMD3<Double>(p),
                              color: existing.color + c,
                              count: existing.count + 1)
        } else {
            // Doygunluğa ulaşıldıysa yeni hücre açma, mevcutları güncellemeye devam et.
            guard cells.count < maxPoints else {
                isSaturated = true
                return
            }
            cells[key] = Cell(position: SIMD3<Double>(p), color: c, count: 1)
        }
    }

    func snapshot() -> CloudSnapshot {
        var out = CloudSnapshot()
        out.positions.reserveCapacity(cells.count)
        out.colors.reserveCapacity(cells.count)
        for (_, cell) in cells {
            let n = cell.count
            out.positions.append(SIMD3<Float>(cell.position / n))
            let c = cell.color / n
            out.colors.append(SIMD3<UInt8>(
                UInt8(clamping: Int(c.x.rounded())),
                UInt8(clamping: Int(c.y.rounded())),
                UInt8(clamping: Int(c.z.rounded()))
            ))
        }
        return out
    }

    func reset() {
        cells.removeAll(keepingCapacity: true)
        isSaturated = false
    }
}
