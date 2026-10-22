import RealityKit
import SwiftUI
import Foundation
import os

/// Apple Object Capture sarmalayıcısı: kılavuzlu çekim + cihaz üstü rekonstrüksiyon.
///
/// `ObjectCaptureSession` @Observable olduğu için canlı çekim durumunu burada
/// kopyalamıyoruz — görünüm `session.state`'i doğrudan okuyor. Bu sınıf yalnızca
/// çekim sonrası aşamaları (rekonstrüksiyon, sonuç, hata) yönetiyor.
@MainActor
final class ObjectCaptureController: ObservableObject {

    enum Phase: Equatable {
        /// Canlı çekim; ayrıntılı durum `session.state` içinde.
        case capturing
        case reconstructing(Double)
        case done
        case failed(String)
    }

    static var isSupported: Bool {
        ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
    }

    @Published private(set) var phase: Phase = .capturing
    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var passCount = 0
    /// Yeni tur isteği gönderildi, oturum henüz `userCompletedScanPass`'i
    /// sıfırlamadı. Bu aralıkta ikinci bir çağrı Apple'ın ön koşulunu bozuyor.
    @Published private(set) var passTransitionPending = false
    @Published private(set) var mesh = MeshData()
    /// Modeli oluşturan fotoğraflar. Telefonda Apple yalnızca `reduced` detay
    /// veriyor; bu klasör Mac'e gidip `raw` detayda yeniden işlenebiliyor.
    /// Telefonda yer kaplamasın diye yalnızca son taramanınki tutuluyor.
    @Published private(set) var imagesFolder: URL?
    @Published private(set) var imageCount = 0

    private static let capturePrefix = "oc_"
    private static var capturesRoot: URL {
        ExportManager.documentsDirectory().appendingPathComponent("Captures", isDirectory: true)
    }

    private var workspace: URL?
    private var imagesDirectory: URL?
    private var reconstructionTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.borayunusoglu.LidarCAD", category: "ObjectCapture")

    // MARK: - Akış

    func begin() {
        cleanUp()
        removePreviousCaptures()
        mesh = MeshData()
        imagesFolder = nil
        imageCount = 0
        passCount = 0
        phase = .capturing

        do {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withFullDate, .withTime])
                .replacingOccurrences(of: ":", with: "")
            let root = Self.capturesRoot
                .appendingPathComponent("\(Self.capturePrefix)\(stamp)", isDirectory: true)
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
            log.info("oturum başladı, durum=\(String(describing: session.state), privacy: .public)")
            print("[ObjectCapture] oturum başladı, durum=\(session.state.label)")
        } catch {
            log.error("oturum başlatılamadı: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Görünüm oturum durumu her değiştiğinde (ve ilk açılışta) çağırır.
    func sync(_ state: ObjectCaptureSession.CaptureState) {
        log.info("durum -> \(String(describing: state), privacy: .public)")
        print("[ObjectCapture] durum -> \(state.label)")
        if case .capturing = state {} else { passTransitionPending = false }
        switch state {
        case .completed:
            guard phase == .capturing else { return }
            // Kamerayı ve çekim belleğini bırak; rekonstrüksiyon için yalnızca
            // fotoğraf klasörü gerekiyor ve cihaz üstü işlem belleğe aç.
            session = nil
            reconstructionTask = Task { await reconstruct() }
        case .failed(let error):
            phase = .failed(error.localizedDescription)
        default:
            break
        }
    }

    func startDetecting() {
        guard let session else { return }
        if !session.startDetecting() {
            log.error("startDetecting false döndü")
        }
    }

    func startCapturing() { session?.startCapturing() }

    /// Tur bitti ve oturum yeni bir tura hazır mı.
    ///
    /// `beginNewScanPass*` koşullar sağlanmadan çağrılırsa RealityKit içinde
    /// bir ön koşul kapanıyla (EXC_BREAKPOINT) çöküyor; mesaj vermiyor. Bu
    /// yüzden çağırmadan önce durumu kendimiz doğruluyoruz.
    func canStartNewPass(_ session: ObjectCaptureSession) -> Bool {
        guard case .capturing = session.state else { return false }
        return session.userCompletedScanPass && !passTransitionPending
    }

    func canFlip(_ session: ObjectCaptureSession) -> Bool {
        canStartNewPass(session) && !session.feedback.contains(.objectNotFlippable)
    }

    /// Nesneyi ters çevirip alt yüzeyini de taramak için yeni tur.
    func beginNewPassAfterFlip() {
        guard let session else { return }
        logPassCall("flip", session)
        guard canFlip(session) else { return }
        passTransitionPending = true
        session.beginNewScanPassAfterFlip()
        passCount += 1
    }

    /// Nesneyi çevirmeden, farklı yükseklikten ikinci tur.
    func beginNewPass() {
        guard let session else { return }
        logPassCall("yeni tur", session)
        guard canStartNewPass(session) else { return }
        passTransitionPending = true
        session.beginNewScanPass()
        passCount += 1
    }

    /// Görünüm, oturum `userCompletedScanPass`'i sıfırladığında çağırır.
    func passDidReset() {
        passTransitionPending = false
    }

    private func logPassCall(_ kind: String, _ session: ObjectCaptureSession) {
        let feedback = session.feedback.map { String(describing: $0) }.sorted().joined(separator: ",")
        let line = "\(kind): durum=\(session.state.label) turBitti=\(session.userCompletedScanPass) bekleyen=\(passTransitionPending) geribildirim=[\(feedback)]"
        log.info("\(line, privacy: .public)")
        print("[ObjectCapture] \(line)")
    }

    func finish() { session?.finish() }

    func cancel() {
        passTransitionPending = false
        reconstructionTask?.cancel()
        reconstructionTask = nil
        session?.cancel()
        // Tamamlanmış bir taramanın fotoğrafları "Mac'e gönder" için kalsın.
        cleanUp()
        phase = .capturing
    }

    // MARK: - Rekonstrüksiyon

    private func reconstruct() async {
        guard let imagesDirectory else {
            phase = .failed("Fotoğraf klasörü bulunamadı.")
            return
        }
        phase = .reconstructing(0)

        do {
            let photogrammetry = try PhotogrammetrySession(input: imagesDirectory)
            // iOS'ta tek detay seviyesi .reduced; diğerleri macOS'a özel.
            try photogrammetry.process(requests: [.modelEntity(detail: .reduced)])

            for try await output in photogrammetry.outputs {
                if Task.isCancelled { return }
                switch output {
                case .requestProgress(_, let fraction):
                    phase = .reconstructing(fraction)
                case .requestComplete(_, let result):
                    if case .modelEntity(let entity) = result {
                        mesh = RealityMeshExtractor.extract(from: entity)
                        log.info("model: \(self.mesh.triangleCount) üçgen")
                    }
                case .processingComplete:
                    if mesh.isEmpty {
                        phase = .failed("Model oluşturulamadı. Nesnenin dokusu yetersiz olabilir.")
                    } else {
                        keepImagesForMac()
                        phase = .done
                    }
                    return
                case .requestError(_, let error):
                    phase = .failed(error.localizedDescription)
                    return
                case .processingCancelled:
                    phase = .failed("İşlem iptal edildi.")
                    return
                default:
                    break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Temizlik

    private func cleanUp() {
        session = nil
        // Model tamamlandıysa fotoğraflar Mac için saklanıyor; ancak yeni bir
        // tarama başlarken removePreviousCaptures() ile gidiyorlar.
        if let workspace, imagesFolder == nil {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
        imagesDirectory = nil
    }

    /// Checkpoint yalnızca telefondaki rekonstrüksiyonu sürdürmek için; Mac'e
    /// fotoğraflar yeter. Yer açmak için siliyoruz.
    private func keepImagesForMac() {
        guard let workspace, let imagesDirectory else { return }
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("Checkpoint"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        imageCount = files.filter { ["heic", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }.count
        imagesFolder = imagesDirectory
    }

    /// Her Nesne taraması yüzlerce MB fotoğraf bırakabilir; yalnızca sonuncusu kalsın.
    private func removePreviousCaptures() {
        let root = Self.capturesRoot
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(Self.capturePrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func archiveImages() throws -> URL {
        guard let imagesFolder else { throw CocoaError(.fileNoSuchFile) }
        // Zip adı klasörün değil taramanın adı olsun (Images.zip değil).
        return try FolderArchiver.zip(imagesFolder, as: imagesFolder.deletingLastPathComponent().lastPathComponent)
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

extension ObjectCaptureSession.CaptureState {
    var label: String {
        switch self {
        case .initializing: return "başlatılıyor"
        case .ready:        return "hazır"
        case .detecting:    return "algılıyor"
        case .capturing:    return "çekiyor"
        case .finishing:    return "bitiriyor"
        case .completed:    return "tamamlandı"
        case .failed:       return "hata"
        @unknown default:   return "bilinmiyor"
        }
    }
}

extension ObjectCaptureSession.Tracking {
    var label: String {
        switch self {
        case .normal:       return "normal"
        case .notAvailable: return "yok"
        case .limited(let reason):
            switch reason {
            case .initializing:         return "sınırlı (başlatılıyor)"
            case .relocalizing:         return "sınırlı (yeniden konumlanıyor)"
            case .excessiveMotion:      return "sınırlı (fazla hareket)"
            case .insufficientFeatures: return "sınırlı (yetersiz doku)"
            @unknown default:           return "sınırlı"
            }
        @unknown default:   return "bilinmiyor"
        }
    }
}
