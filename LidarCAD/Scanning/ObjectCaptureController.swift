import RealityKit
import SwiftUI
import Foundation

/// Apple Object Capture sarmalayıcısı: kılavuzlu çekim + cihaz üstü rekonstrüksiyon.
///
/// LiDAR mesh'i küçük nesneler için fazla kaba kalıyor (derinlik haritası
/// 256x192). Object Capture fotoğramtetri kullanıp LiDAR'dan yalnızca ölçek
/// alıyor — CAD için kritik olan doğru boyut böylece korunuyor.
@MainActor
final class ObjectCaptureController: ObservableObject {

    enum Stage: Equatable {
        case idle
        case ready          // nesneye doğrult
        case detecting      // sınır kutusu ayarlanıyor
        case capturing
        case finishing
        case reconstructing(Double)
        case done
        case failed(String)
    }

    static var isSupported: Bool {
        ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var feedback: Set<ObjectCaptureSession.Feedback> = []
    @Published private(set) var shotsTaken = 0
    @Published private(set) var maximumShots = 0
    @Published private(set) var completedPass = false
    @Published private(set) var passCount = 0
    @Published private(set) var mesh = MeshData()

    private var workspace: URL?
    private var imagesDirectory: URL?
    private var observers: [Task<Void, Never>] = []

    // MARK: - Akış

    func begin() {
        cleanUp()
        mesh = MeshData()
        passCount = 0
        completedPass = false
        shotsTaken = 0

        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectCapture/\(UUID().uuidString)", isDirectory: true)
            let images = root.appendingPathComponent("Images", isDirectory: true)
            let checkpoint = root.appendingPathComponent("Checkpoint", isDirectory: true)
            // start(imagesDirectory:) dizinin var ve boş olmasını şart koşuyor.
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            workspace = root
            imagesDirectory = images

            let session = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = checkpoint
            configuration.isOverCaptureEnabled = true
            session.start(imagesDirectory: images, configuration: configuration)

            self.session = session
            self.maximumShots = session.maximumNumberOfInputImages
            observe(session)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func startDetecting() {
        guard let session else { return }
        _ = session.startDetecting()
    }

    func startCapturing() {
        session?.startCapturing()
    }

    /// Nesneyi ters çevirip alt yüzeyini de taramak için yeni tur.
    func beginNewPassAfterFlip() {
        guard let session else { return }
        session.beginNewScanPassAfterFlip()
        passCount += 1
        completedPass = false
    }

    /// Nesneyi çevirmeden, aynı duruşta ikinci tur (farklı yükseklikten).
    func beginNewPass() {
        guard let session else { return }
        session.beginNewScanPass()
        passCount += 1
        completedPass = false
    }

    func finish() {
        session?.finish()
    }

    func cancel() {
        session?.cancel()
        cleanUp()
        stage = .idle
    }

    // MARK: - Durum akışları

    private func observe(_ session: ObjectCaptureSession) {
        observers.append(Task { [weak self] in
            for await state in session.stateUpdates {
                guard let self else { return }
                self.handle(state)
            }
        })
        observers.append(Task { [weak self] in
            for await value in session.feedbackUpdates { self?.feedback = value }
        })
        observers.append(Task { [weak self] in
            for await value in session.numberOfShotsTakenUpdates { self?.shotsTaken = value }
        })
        observers.append(Task { [weak self] in
            for await value in session.userCompletedScanPassUpdates { self?.completedPass = value }
        })
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .initializing:
            stage = .idle
        case .ready:
            stage = .ready
        case .detecting:
            stage = .detecting
        case .capturing:
            stage = .capturing
        case .finishing:
            stage = .finishing
        case .completed:
            Task { await reconstruct() }
        case .failed(let error):
            stage = .failed(error.localizedDescription)
        @unknown default:
            break
        }
    }

    // MARK: - Rekonstrüksiyon

    private func reconstruct() async {
        guard let imagesDirectory else {
            stage = .failed("Fotoğraf klasörü bulunamadı.")
            return
        }
        stage = .reconstructing(0)

        do {
            let photogrammetry = try PhotogrammetrySession(input: imagesDirectory)
            // iOS'ta tek detay seviyesi .reduced; diğerleri macOS'a özel.
            try photogrammetry.process(requests: [.modelEntity(detail: .reduced)])

            for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    stage = .reconstructing(fraction)

                case .requestComplete(_, let result):
                    if case .modelEntity(let entity) = result {
                        mesh = RealityMeshExtractor.extract(from: entity)
                    }

                case .processingComplete:
                    if mesh.isEmpty {
                        stage = .failed("Model oluşturulamadı. Nesnenin dokusu yetersiz olabilir.")
                    } else {
                        stage = .done
                    }
                    return

                case .requestError(_, let error):
                    stage = .failed(error.localizedDescription)
                    return

                case .processingCancelled:
                    stage = .failed("İşlem iptal edildi.")
                    return

                default:
                    break
                }
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Temizlik

    private func cleanUp() {
        observers.forEach { $0.cancel() }
        observers.removeAll()
        session = nil
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
        imagesDirectory = nil
    }

    deinit {
        observers.forEach { $0.cancel() }
    }
}

extension ObjectCaptureSession.Feedback {
    var message: String? {
        switch self {
        case .objectTooClose:        return "Çok yakınsınız — biraz geri çekilin"
        case .objectTooFar:          return "Çok uzaksınız — yaklaşın"
        case .movingTooFast:         return "Çok hızlısınız — yavaşlayın"
        case .environmentLowLight:   return "Işık az — ortamı aydınlatın"
        case .environmentTooDark:    return "Ortam çok karanlık"
        case .outOfFieldOfView:      return "Nesne kadrajdan çıktı"
        case .objectNotFlippable:    return "Bu nesne çevrilmeye uygun değil"
        case .objectNotDetected:     return "Nesne algılanamadı"
        case .overCapturing:         return "Yeterince fotoğraf alındı"
        @unknown default:            return nil
        }
    }
}
