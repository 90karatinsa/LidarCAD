import AVFoundation
import CoreMotion
import UIKit
import os

/// "Fotoğraf seti" modu: telefon sabit, nesne döner. LiDAR derinlik
/// kamerasıyla HEIC çeker (derinlik dosyaya gömülü — ölçek Mac'te buradan
/// gelir) ve sahne durulunca otomatik deklanşöre basar.
@MainActor
final class PhotoCaptureController: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case configuring
        case ready
        case moving
        case settling(Double)
        case capturing
        case finished(URL)
        case failed(String)
    }

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var shotCount = 0
    @Published private(set) var shotsInPass = 0
    @Published private(set) var pass = 0
    @Published private(set) var depthEnabled = false
    @Published private(set) var lastThumbnail: UIImage?
    @Published var autoCapture = true

    /// Tur başına önerilen çekim sayısı (10° adım ≈ 36).
    let recommendedPerPass = 36

    // AV nesneleri yalnızca sessionQueue'da yapılandırılır; önizleme katmanı
    // `session`'ı sadece okur. AVCaptureSession başlat/durdur için
    // iş parçacığı güvenli, bu yüzden aktör yalıtımının dışında tutuyoruz.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.lidarcad.photo.session")
    private let analysisQueue = DispatchQueue(label: "com.lidarcad.photo.analysis")
    private let detector = StillnessDetector()
    private let motion = CMMotionManager()
    private let log = Logger(subsystem: "com.borayunusoglu.LidarCAD", category: "PhotoCapture")

    /// Yalnızca sessionQueue'da okunur/yazılır.
    nonisolated(unsafe) private var device: AVCaptureDevice?
    private var folder: URL?
    private var manifest: CaptureManifest?
    private var captureInFlight = false
    private var exposureLocked = false
    private var pendingGravity: [Double]?
    private var lastEvent: StillnessDetector.Event = .idle

    // MARK: - Başlat / bitir

    func begin() {
        status = .configuring
        shotCount = 0
        shotsInPass = 0
        pass = 0
        lastThumbnail = nil
        exposureLocked = false
        captureInFlight = false
        analysisQueue.async { [detector] in detector.reset() }

        do {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withFullDate, .withTime])
                .replacingOccurrences(of: ":", with: "")
            let root = ExportManager.documentsDirectory().appendingPathComponent("Captures", isDirectory: true)
            let folder = root.appendingPathComponent("nesne_\(stamp)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.folder = folder
            manifest = CaptureManifest(device: Self.modelIdentifier(), createdAt: Date())
            try manifest?.save(to: folder)
        } catch {
            status = .failed("Klasör oluşturulamadı: \(error.localizedDescription)")
            return
        }

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates()
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.configureSession()
            Task { @MainActor in
                switch result {
                case .success(let depth):
                    self.depthEnabled = depth
                    self.status = .ready
                case .failure(let message):
                    self.status = .failed(message)
                }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        sessionQueue.async { [weak self] in
            guard let session = self?.session, session.isRunning else { return }
            session.stopRunning()
        }
    }

    func finish() {
        stop()
        guard let folder else { return }
        status = .finished(folder)
    }

    /// Nesne yan yatırıldı / ters çevrildi: yeni tur. Fotogrametri her turu
    /// ayrı bakış grubu olarak değerlendirir; Mac aracı da çok turlu setlerde
    /// yerçekimini kullanmaz.
    func startNewPass() {
        pass += 1
        shotsInPass = 0
        analysisQueue.async { [detector] in detector.reset() }
    }

    // MARK: - Oturum kurulumu (sessionQueue)

    private enum SetupResult { case success(Bool), failure(String) }

    nonisolated private func configureSession() -> SetupResult {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            return .failure("LiDAR kamera bulunamadı.")
        }

        // Moda ikinci girişte oturum zaten kurulu: sadece yeniden başlat.
        if !session.inputs.isEmpty {
            if !session.isRunning { session.startRunning() }
            return .success(photoOutput.isDepthDataDeliveryEnabled)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return .failure("Kamera girişi eklenemedi.") }
            session.addInput(input)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard session.canAddOutput(photoOutput) else { return .failure("Fotoğraf çıkışı eklenemedi.") }
        session.addOutput(photoOutput)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Derinlik destekleyen biçimler arasından en büyük fotoğrafı vereni seç.
        func area(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
        let depthFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        if let format = depthFormats.max(by: {
            area($0.supportedMaxPhotoDimensions.max(by: { area($0) < area($1) }) ?? CMVideoDimensions())
                < area($1.supportedMaxPhotoDimensions.max(by: { area($0) < area($1) }) ?? CMVideoDimensions())
        }) {
            let depthFormat = format.supportedDepthDataFormats
                .filter {
                    let t = $0.formatDescription.mediaSubType.rawValue
                    return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DepthFloat16
                }
                .max { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                if let depthFormat { device.activeDepthDataFormat = depthFormat }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                device.unlockForConfiguration()
            } catch {
                return .failure("Kamera ayarlanamadı: \(error.localizedDescription)")
            }
            if let best = format.supportedMaxPhotoDimensions.max(by: { area($0) < area($1) }) {
                photoOutput.maxPhotoDimensions = best
            }
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported

        self.device = device
        session.startRunning()
        return .success(photoOutput.isDepthDataDeliveryEnabled)
    }

    // MARK: - Çekim

    func capture(manual: Bool = true) {
        guard !captureInFlight, folder != nil else { return }
        if case .finished = status { return }
        captureInFlight = true
        status = .capturing
        if manual { analysisQueue.async { [detector] in detector.disarm() } }

        if let g = motion.deviceMotion?.gravity {
            pendingGravity = [g.x, g.y, g.z]
        } else {
            pendingGravity = nil
        }

        // Ayarlar çıkışın durumuna bağlı; çıkışın sahibi olan kuyrukta kuruluyor.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let output = self.photoOutput
            let codec: AVVideoCodecType = output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.isDepthDataDeliveryEnabled = output.isDepthDataDeliveryEnabled
            settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
            settings.isDepthDataFiltered = settings.isDepthDataDeliveryEnabled
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func store(_ data: Data?, hasDepth: Bool, error: Error?) {
        captureInFlight = false
        guard let folder, var manifest else { return }
        guard let data, error == nil else {
            log.error("çekim başarısız: \(error?.localizedDescription ?? "veri yok", privacy: .public)")
            status = .ready
            return
        }

        let index = manifest.shots.count + 1
        let ext = data.starts(with: [0xFF, 0xD8]) ? "JPG" : "HEIC"
        let name = String(format: "IMG_%04d.%@", index, ext)
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            manifest.shots.append(.init(file: name, pass: pass, gravity: pendingGravity, hasDepth: hasDepth))
            try manifest.save(to: folder)
            self.manifest = manifest
        } catch {
            status = .failed("Fotoğraf kaydedilemedi: \(error.localizedDescription)")
            return
        }

        shotCount = manifest.shots.count
        shotsInPass += 1
        lastThumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 160, height: 120))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // İlk çekimden sonra pozlama, beyaz dengesi ve odağı kilitle: döner
        // tablada bunların kareden kareye oynaması fotogrametriyi bozar.
        if !exposureLocked {
            exposureLocked = true
            sessionQueue.async { [weak self] in
                guard let device = self?.device, (try? device.lockForConfiguration()) != nil else { return }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                device.unlockForConfiguration()
            }
        }
        status = .ready
    }

    private func handle(_ event: StillnessDetector.Event) {
        if case .finished = status { return }
        if case .failed = status { return }
        if captureInFlight { return }
        switch event {
        case .moving:
            status = .moving
        case .settling(let progress):
            status = autoCapture ? .settling(progress) : .ready
        case .still:
            if autoCapture { capture(manual: false) } else { status = .ready }
        case .idle:
            if case .settling = status { status = .ready }
            if case .moving = status { status = .ready }
        }
    }

    // MARK: - Paylaşım

    /// Klasörü tek bir zip olarak paketler (AirDrop'ta tek dosya, Mac'te
    /// `lidarcad-reconstruct` doğrudan zip'i de açıyor).
    func makeArchive() throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        var coordinatorError: NSError?
        var archive: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinatorError) { zipURL in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent + ".zip")
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

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - AVFoundation delegeleri

extension PhotoCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        let hasDepth = photo.depthData != nil
        Task { @MainActor [weak self] in self?.store(data, hasDepth: hasDepth, error: error) }
    }
}

extension PhotoCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let event = detector.process(buffer)
        // Ana iş parçacığını her karede yormayalım: yalnızca olay değişince
        // (durulma ilerlemesini %10'luk adımlarla) haber ver.
        let quantized: StillnessDetector.Event
        if case .settling(let p) = event { quantized = .settling((p * 10).rounded(.down) / 10) } else { quantized = event }
        Task { @MainActor [weak self] in
            guard let self, quantized != self.lastEvent || quantized == .still else { return }
            self.lastEvent = quantized
            self.handle(quantized)
        }
    }
}
