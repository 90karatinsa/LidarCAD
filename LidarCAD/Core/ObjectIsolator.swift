import Foundation
import simd

/// Masada duran bir nesnenin taramasından masayı ve arka plan kırıntılarını ayıklar.
///
/// Döner tabla çekiminde nesneyle birlikte dönen her şey (sehpa üstü, altlık)
/// fotogrametriye göre nesnenin parçası. Burada destek düzlemini bulup atıyoruz
/// ve geriye kalanlardan düzleme oturan parçayı tutuyoruz. Düzlem aynı zamanda
/// nesnenin "zemin"i: boyu düzleme olan uzaklıkla ölçülüyor, böylece kesim
/// payı yüksekliği değiştirmiyor.
enum ObjectIsolator {

    /// Teşhis için: verilirse ara adımları yazar (Mac aracında --trace-isolate).
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    struct Plane: Equatable {
        /// Birim normal, nesnenin bulunduğu tarafa bakar.
        var normal: SIMD3<Float>
        var offset: Float          // n·p + offset = 0

        func distance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p) + offset }
    }

    struct Result {
        var mesh: MeshData
        var plane: Plane
        /// Düzlemin altında / üstündeki kesim kalınlığı (metre).
        var cutThickness: Float
        var removedTriangles: Int
        /// Nesnenin düzlemden en uzak noktası — gerçek yüksekliği.
        var height: Float
    }

    // MARK: - Ana giriş

    /// - Parameter up: Biliniyorsa yukarı yönü (yerçekimiyle hizalı modeller).
    ///   Verilirse yalnızca yataya yakın düzlemler aday olur. nil ise düzlem
    ///   yönü serbest, nesne tarafı da otomatik seçilir.
    static func isolate(_ mesh: MeshData, up: SIMD3<Float>?) -> Result? {
        guard mesh.triangleCount >= 20 else { return nil }
        let faces = FaceInfo(mesh)
        guard faces.totalArea > 0 else { return nil }

        // Gürültü ölçeği modelin boyutuna göre: 1 m'lik masada 4 mm, küçük
        // nesnede daha ince.
        let size = mesh.bounds().map { simd_length($0.size) } ?? 1
        let coarse = min(max(size * 0.006, 0.0015), 0.008)

        // En büyük düzlem destek olmayabilir: masanın altındaki zemin daha
        // büyük çıkabilir ama nesne zemine değil masaya oturuyor. Birkaç düzlem
        // bulup üstünde bir şey oturanları aday sayıyoruz.
        let planes = findPlanes(faces, up: up, threshold: coarse, maxCount: 4)
        trace?("üçgen \(faces.count), toplam alan \(faces.totalArea), kaba eşik \(coarse), bulunan düzlem \(planes.count)")
        var candidates: [Result] = []
        for var plane in planes {
            let cut = cutThickness(faces, plane: plane, coarse: coarse)
            trace?("düzlem n=\(plane.normal) ofset=\(plane.offset) kesim=\(cut)")
            if let up {
                if simd_dot(plane.normal, up) < 0 { plane = flipped(plane) }
                if let r = keepResting(mesh, faces, plane: plane, cut: cut) { candidates.append(r) }
            } else {
                // Yukarı bilinmiyorsa nesne tarafı, oturan parçası büyük olan taraf.
                let a = keepResting(mesh, faces, plane: plane, cut: cut)
                let b = keepResting(mesh, faces, plane: flipped(plane), cut: cut)
                if let best = [a, b].compactMap({ $0 }).max(by: { area($0.mesh) < area($1.mesh) }) {
                    candidates.append(best)
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        if let up {
            // Nesne doğrudan en yüksek desteğe oturur (masa > zemin). Zemin
            // seçilseydi masa da "nesne" olurdu.
            return candidates.max { height(of: $0.plane, along: up) < height(of: $1.plane, along: up) }
        }
        return candidates.first
    }

    private static func height(of plane: Plane, along up: SIMD3<Float>) -> Float {
        simd_dot(-plane.normal * plane.offset, up)
    }

    /// Kesim kalınlığı düzlemin gerçek gürültüsünden: inlier uzaklıklarının
    /// %90'lık dilimi, 1 mm ile kaba eşik arasında.
    private static func cutThickness(_ faces: FaceInfo, plane: Plane, coarse: Float) -> Float {
        var distances: [Float] = []
        for f in 0..<faces.count where abs(plane.distance(faces.centroid[f])) < coarse
            && abs(simd_dot(faces.normal[f], plane.normal)) > 0.94 {
            distances.append(abs(plane.distance(faces.centroid[f])))
        }
        distances.sort()
        let p90 = distances.isEmpty ? coarse : distances[Int(Float(distances.count - 1) * 0.9)]
        return min(max(p90 * 1.5, 0.001), coarse)
    }

    struct Placement {
        var rotation: simd_quatf
        var translation: SIMD3<Float>
        func apply(_ p: SIMD3<Float>) -> SIMD3<Float> { rotation.act(p) + translation }
    }

    /// Düzlemi `up` eksenine dik yatırır ve sıfıra taşır; nesneyi diğer iki
    /// eksende ortalar. Düzlem normali yukarıyı verdiği için yerçekimi
    /// verisi olmadan da nesne dik durur.
    static func placement(for mesh: MeshData, on plane: Plane, up: SIMD3<Float>) -> Placement {
        let rotation = simd_quatf(from: plane.normal, to: up)
        let onPlane = -plane.normal * plane.offset
        let planeHeight = simd_dot(rotation.act(onPlane), up)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in mesh.positions {
            let r = rotation.act(p)
            lo = simd_min(lo, r); hi = simd_max(hi, r)
        }
        let center = (lo + hi) * 0.5
        // Yukarı eksende düzlem sıfıra, diğer eksenlerde merkez sıfıra.
        let translation = -(center - up * simd_dot(center, up)) - up * planeHeight
        return Placement(rotation: rotation, translation: translation)
    }

    static func apply(_ placement: Placement, to mesh: MeshData) -> MeshData {
        var out = mesh
        for i in out.positions.indices { out.positions[i] = placement.apply(out.positions[i]) }
        for i in out.normals.indices { out.normals[i] = placement.rotation.act(out.normals[i]) }
        return out
    }

    // MARK: - Düzlem bulma (alan ağırlıklı RANSAC)

    /// Sıralı RANSAC: en iyi düzlemi bul, inlier'larını çıkar, tekrarla.
    private static func findPlanes(_ faces: FaceInfo, up: SIMD3<Float>?, threshold: Float, maxCount: Int) -> [Plane] {
        var used = [Bool](repeating: false, count: faces.count)
        var planes: [Plane] = []
        for round in 0..<maxCount {
            guard let plane = findPlane(faces, up: up, threshold: threshold, excluding: used,
                                        seed: 0x5EED_1234 &+ UInt64(round)) else { break }
            planes.append(plane)
            for g in 0..<faces.count where abs(plane.distance(faces.centroid[g])) < threshold * 2 {
                used[g] = true
            }
        }
        return planes
    }

    private static func findPlane(_ faces: FaceInfo, up: SIMD3<Float>?, threshold: Float,
                                  excluding used: [Bool], seed: UInt64) -> Plane? {
        var rng = SplitMix(seed: seed)
        var best: (plane: Plane, score: Float)?
        let normalTolerance: Float = 0.94          // ~20°
        let upTolerance: Float = 0.9               // ~25° yataydan sapma

        var attempts = 0
        for _ in 0..<2000 {
            let f = faces.sampleByArea(&rng)
            if used[f] { continue }
            let n = faces.normal[f]
            if let up, abs(simd_dot(n, up)) < upTolerance { continue }
            attempts += 1
            if attempts > 500 { break }
            let candidate = Plane(normal: n, offset: -simd_dot(n, faces.centroid[f]))

            var score: Float = 0
            for g in 0..<faces.count where !used[g] {
                if abs(candidate.distance(faces.centroid[g])) < threshold,
                   abs(simd_dot(faces.normal[g], n)) > normalTolerance {
                    score += faces.area[g]
                }
            }
            if score > (best?.score ?? 0) { best = (candidate, score) }
        }
        trace?("  RANSAC en iyi puan \(best?.score ?? 0) / \(faces.totalArea) (deneme \(attempts))")
        guard var plane = best?.plane, let score = best?.score,
              score >= faces.totalArea * 0.05 else { return nil }

        // İnlier'lardan alan ağırlıklı iyileştirme.
        var nSum = SIMD3<Float>.zero, cSum = SIMD3<Float>.zero, aSum: Float = 0
        for g in 0..<faces.count where !used[g] && abs(plane.distance(faces.centroid[g])) < threshold
            && abs(simd_dot(faces.normal[g], plane.normal)) > normalTolerance {
            let sign: Float = simd_dot(faces.normal[g], plane.normal) >= 0 ? 1 : -1
            nSum += faces.normal[g] * faces.area[g] * sign
            cSum += faces.centroid[g] * faces.area[g]
            aSum += faces.area[g]
        }
        if aSum > 0, simd_length(nSum) > 0 {
            let n = simd_normalize(nSum)
            plane = Plane(normal: n, offset: -simd_dot(n, cSum / aSum))
        }
        return plane
    }

    private static func flipped(_ p: Plane) -> Plane { Plane(normal: -p.normal, offset: -p.offset) }

    // MARK: - Ayıklama

    private static func keepResting(_ mesh: MeshData, _ faces: FaceInfo, plane: Plane, cut: Float) -> Result? {
        // Masanın kendi üçgenleri tamamen düzlem kalınlığında ya da altında:
        // en az bir köşesi kesim payının üstüne çıkmayan üçgen gider. Nesnenin
        // tabana inen yan üçgenleri kalır — fotogrametri mesh'inde bunlar
        // büyük ve tabana değiyor; "tabana değeni at" kuralı yan yüzün
        // tamamını götürüp nesneyi havada bir üst yüze indiriyordu.
        var keep = [Bool](repeating: false, count: mesh.triangleCount)
        for f in 0..<mesh.triangleCount {
            let a = plane.distance(mesh.positions[Int(mesh.indices[f * 3])])
            let b = plane.distance(mesh.positions[Int(mesh.indices[f * 3 + 1])])
            let c = plane.distance(mesh.positions[Int(mesh.indices[f * 3 + 2])])
            keep[f] = max(a, b, c) > cut
        }

        // Doku dikişlerinde vertexler çoğaltılmış olabilir (aynı konum, farklı UV);
        // bağlılığı konuma göre kuruyoruz, yoksa tek yüzey onlarca parçaya bölünür.
        let welded = weld(mesh.positions)
        var parent = Array(0..<welded.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        for f in 0..<mesh.triangleCount where keep[f] {
            let a = welded.id[Int(mesh.indices[f * 3])]
            union(a, welded.id[Int(mesh.indices[f * 3 + 1])])
            union(a, welded.id[Int(mesh.indices[f * 3 + 2])])
        }

        struct Component { var area: Float = 0; var minDistance: Float = .greatestFiniteMagnitude }
        var components: [Int: Component] = [:]
        for f in 0..<mesh.triangleCount where keep[f] {
            let root = find(welded.id[Int(mesh.indices[f * 3])])
            var comp = components[root, default: Component()]
            comp.area += faces.area[f]
            for k in 0..<3 {
                comp.minDistance = min(comp.minDistance, plane.distance(mesh.positions[Int(mesh.indices[f * 3 + k])]))
            }
            components[root] = comp
        }

        // Düzleme oturanlar: en alt noktası kesim payının hemen üstünde.
        let resting = components.filter { $0.value.minDistance < cut * 4 }
        let keptCount = keep.filter { $0 }.count
        trace?("  taraf n=\(plane.normal): kalan üçgen \(keptCount), parça \(components.count), oturan \(resting.count), en büyük parça alanı \(components.values.map(\.area).max() ?? 0), en alçak \(components.values.map(\.minDistance).min() ?? -1)")
        guard let largest = resting.max(by: { $0.value.area < $1.value.area }) else { return nil }
        // Çok parçalı nesneler için büyüğün %30'undan büyük oturan parçalar da
        // kalsın; masa gürültüsünden kalan ufak sivrilikler elensin.
        let chosen = Set(resting.filter { $0.value.area >= largest.value.area * 0.3 }.map(\.key))

        var out = MeshData()
        var remap = [Int32](repeating: -1, count: mesh.vertexCount)
        let hasNormals = mesh.normals.count == mesh.vertexCount
        var height: Float = 0
        var removed = 0
        for f in 0..<mesh.triangleCount {
            guard keep[f], chosen.contains(find(welded.id[Int(mesh.indices[f * 3])])) else { removed += 1; continue }
            for k in 0..<3 {
                let old = Int(mesh.indices[f * 3 + k])
                if remap[old] < 0 {
                    remap[old] = Int32(out.positions.count)
                    out.positions.append(mesh.positions[old])
                    if hasNormals { out.normals.append(mesh.normals[old]) }
                    height = max(height, plane.distance(mesh.positions[old]))
                }
                out.indices.append(UInt32(remap[old]))
            }
            out.faceClasses.append(f < mesh.faceClasses.count ? mesh.faceClasses[f] : 0)
        }
        guard !out.isEmpty else { return nil }

        // Düzlem gerçekten bir destek mi? Nesnenin düzleme izdüşüm alanından
        // en az iki kat büyük olmalı. Masasız bir nesnede (Object Capture
        // çıktısı, tek başına bir kutu) en büyük düz yüz nesnenin kendi
        // yüzüdür; onu "masa" sanıp kesmeyelim.
        let (u, v) = basis(plane.normal)
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in out.positions {
            let q = SIMD2(simd_dot(p, u), simd_dot(p, v))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let footprint = max((hi.x - lo.x) * (hi.y - lo.y), 1e-8)
        var planeArea: Float = 0
        for f in 0..<faces.count where abs(plane.distance(faces.centroid[f])) < cut * 2
            && abs(simd_dot(faces.normal[f], plane.normal)) > 0.94 {
            planeArea += faces.area[f]
        }
        trace?("  destek kontrolü: düzlem alanı \(planeArea), nesne izdüşümü \(footprint), kalan üçgen \(out.triangleCount)")
        guard planeArea >= footprint * 2 else { return nil }

        return Result(mesh: out, plane: plane, cutThickness: cut, removedTriangles: removed, height: height)
    }

    private static func basis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(n, helper))
        return (u, simd_cross(n, u))
    }

    private static func area(_ mesh: MeshData) -> Float {
        (0..<mesh.triangleCount).reduce(0) { sum, f in
            let a = mesh.positions[Int(mesh.indices[f * 3])]
            let b = mesh.positions[Int(mesh.indices[f * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[f * 3 + 2])]
            return sum + simd_length(simd_cross(b - a, c - a)) * 0.5
        }
    }

    // MARK: - Yardımcılar

    private struct FaceInfo {
        var centroid: [SIMD3<Float>] = []
        var normal: [SIMD3<Float>] = []
        var area: [Float] = []
        var cumulative: [Float] = []
        var totalArea: Float = 0
        var count: Int { area.count }

        init(_ mesh: MeshData) {
            centroid.reserveCapacity(mesh.triangleCount)
            for f in 0..<mesh.triangleCount {
                let a = mesh.positions[Int(mesh.indices[f * 3])]
                let b = mesh.positions[Int(mesh.indices[f * 3 + 1])]
                let c = mesh.positions[Int(mesh.indices[f * 3 + 2])]
                let cross = simd_cross(b - a, c - a)
                let len = simd_length(cross)
                centroid.append((a + b + c) / 3)
                normal.append(len > 0 ? cross / len : SIMD3(0, 0, 1))
                area.append(len * 0.5)
                totalArea += len * 0.5
                cumulative.append(totalArea)
            }
        }

        /// Büyük yüzeyler daha sık seçilsin diye alan ağırlıklı örnekleme.
        func sampleByArea(_ rng: inout SplitMix) -> Int {
            let r = Float(rng.next() % 1_000_000) / 1_000_000 * totalArea
            var lo = 0, hi = cumulative.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < r { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    private static func weld(_ positions: [SIMD3<Float>]) -> (id: [Int], count: Int) {
        var table: [SIMD3<Int32>: Int] = [:]
        var ids = [Int](repeating: 0, count: positions.count)
        let q: Float = 1e5   // 0,01 mm
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x * q).rounded()), Int32((p.y * q).rounded()), Int32((p.z * q).rounded()))
            if let id = table[key] { ids[i] = id } else { ids[i] = table.count; table[key] = ids[i] }
        }
        return (ids, table.count)
    }

    /// Tekrarlanabilir sonuç için tohumlu üreteç.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
