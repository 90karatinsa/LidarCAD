import Foundation

/// Fotoğraf seti klasörünün içindekiler: iPhone yazar, Mac'teki
/// `lidarcad-reconstruct` okur. Foundation dışında bağımlılığı yok ki iki
/// tarafta da aynı dosya derlensin.
struct CaptureManifest: Codable, Equatable {
    static let fileName = "capture.json"
    static let currentVersion = 1

    struct Shot: Codable, Equatable {
        /// Klasöre göre göreli dosya adı (IMG_0001.HEIC).
        var file: String
        /// Kaçıncı tur. Nesne her ters çevrildiğinde artar.
        var pass: Int
        /// Çekim anındaki yerçekimi, cihaz koordinatlarında, g biriminde.
        var gravity: [Double]?
        /// Fotoğrafa LiDAR derinliği gömülü mü.
        var hasDepth: Bool
    }

    var version: Int = CaptureManifest.currentVersion
    var device: String
    var createdAt: Date
    var shots: [Shot] = []

    var passCount: Int { (shots.map(\.pass).max() ?? -1) + 1 }

    /// Yerçekimi yalnızca tek turlu setlerde tutarlı: nesne çevrildikten
    /// sonra kameranın "aşağı"sı nesneye göre değişir ve fotogrametriyi
    /// yanıltır.
    var gravityIsConsistent: Bool {
        passCount <= 1 && shots.allSatisfy { $0.gravity?.count == 3 }
    }

    static func load(from folder: URL) throws -> CaptureManifest {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureManifest.self, from: data)
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
