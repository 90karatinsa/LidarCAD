import Foundation
import simd

/// Minimal AutoCAD R12 DXF (sadece LINE entity'leri).
///
/// Fusion 360: `Insert > Insert DXF` -> kesit doğrudan bir skeç'e düşer,
/// üstünden ölçülendirilmiş temiz geometri çizebilirsiniz.
/// R12'yi bilerek seçtik: LWPOLYLINE gibi yeni entity'ler olmadığı için
/// her CAD okuyucusu sorunsuz açar.
enum DXFWriter {

    static func data(segments: [SectionSlicer.Segment], unit: LengthUnit, layer: String = "0") -> Data {
        var out = TextBuffer()
        let d = unit.decimals

        func pair(_ code: Int, _ value: String) {
            out.line("\(code)")
            out.line(value)
        }

        pair(0, "SECTION")
        pair(2, "HEADER")
        pair(9, "$ACADVER");  pair(1, "AC1009")
        pair(9, "$INSUNITS"); pair(70, "\(unit.dxfInsUnits)")
        pair(0, "ENDSEC")

        pair(0, "SECTION")
        pair(2, "ENTITIES")
        for s in segments {
            pair(0, "LINE")
            pair(8, layer)
            pair(10, fixedString(s.a.x, decimals: d))
            pair(20, fixedString(s.a.y, decimals: d))
            pair(30, "0.0")
            pair(11, fixedString(s.b.x, decimals: d))
            pair(21, fixedString(s.b.y, decimals: d))
            pair(31, "0.0")
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")

        return out.finalized()
    }
}
