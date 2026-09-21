import Foundation

/// Küçük little-endian yazma yardımcıları.
/// Apple platformları zaten little-endian ama STL/PLY spesifikasyonu
/// byte sırasını açıkça şart koştuğu için dönüşümü explicit yapıyoruz.
struct BinaryBuffer {
    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    mutating func append(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func append(_ value: UInt16) {
        let v = value.littleEndian
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func append(_ value: UInt32) {
        let v = value.littleEndian
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(ascii string: String) {
        bytes.append(contentsOf: Array(string.utf8))
    }

    mutating func append(rawBytes: [UInt8]) {
        bytes.append(contentsOf: rawBytes)
    }

    var data: Data { Data(bytes) }
    var count: Int { bytes.count }
}

/// Metin export'larında satırları biriktirip toplu yazmak için.
/// Tek bir String'e milyonlarca kez `+=` yapmak katlanılmaz derecede yavaş.
struct TextBuffer {
    private var chunk: String = ""
    private var data = Data()
    private let flushThreshold: Int

    init(flushThreshold: Int = 1 << 20) {
        self.flushThreshold = flushThreshold
        chunk.reserveCapacity(flushThreshold + 4096)
    }

    mutating func line(_ string: String) {
        chunk += string
        chunk += "\n"
        if chunk.utf8.count >= flushThreshold { flush() }
    }

    private mutating func flush() {
        data.append(contentsOf: chunk.utf8)
        chunk.removeAll(keepingCapacity: true)
    }

    mutating func finalized() -> Data {
        flush()
        return data
    }
}
