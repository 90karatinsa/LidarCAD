import Foundation

/// Bir klasörü AirDrop'ta tek dosya olarak gidecek bir zip'e paketler.
/// NSFileCoordinator'ın `.forUploading` seçeneği iOS'ta yerleşik zip'leyici.
enum FolderArchiver {
    static func zip(_ folder: URL, as name: String? = nil) throws -> URL {
        var coordinatorError: NSError?
        var archive: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinatorError) { zipURL in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent((name ?? folder.lastPathComponent) + ".zip")
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipURL, to: target)
                archive = target
            } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let archive else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }
}
