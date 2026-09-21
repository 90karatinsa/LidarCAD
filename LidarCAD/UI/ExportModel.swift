import Foundation
import SwiftUI

@MainActor
final class ExportModel: ObservableObject {

    @Published var options = ExportOptions() {
        didSet { if options != oldValue { previewNeedsRefresh = true } }
    }

    @Published private(set) var previewTriangles: Int?
    @Published private(set) var isPreviewing = false
    @Published private(set) var isExporting = false
    @Published var exportedURLs: [URL] = []
    @Published var errorMessage: String?

    private var previewNeedsRefresh = false
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    /// Seçenekler değiştikçe "kaç üçgen çıkacak" sayısını arka planda hesaplar.
    /// Fusion'da Convert Mesh'in sınırına takılmamak için export öncesi bilmek şart.
    func refreshPreview(mesh: MeshData, force: Bool = false) {
        guard force || previewNeedsRefresh else { return }
        previewNeedsRefresh = false
        previewTask?.cancel()

        let snapshot = mesh
        let current = options
        isPreviewing = true

        previewTask = Task { [weak self] in
            // Kullanıcı sürgüyü oynatırken her adımda hesaplamayalım.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let count = await Task.detached(priority: .userInitiated) {
                MeshPipeline.previewTriangleCount(mesh: snapshot, options: current)
            }.value

            guard !Task.isCancelled else { return }
            self?.previewTriangles = count
            self?.isPreviewing = false
        }
    }

    func export(mesh: MeshData, cloud: CloudSnapshot) {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil

        let current = options
        let name = ExportManager.defaultScanName()

        exportTask = Task { [weak self] in
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try ExportManager.write(mesh: mesh, cloud: cloud,
                                            options: current, name: name)
                }.value
                self?.exportedURLs = urls
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }
}
