import ARKit
import RealityKit
import Combine
import Foundation
import QuartzCore

/// AR oturumunun sahibi. Mesh anchor'larını biriktirir, derinlik karelerini
/// nokta bulutuna açar, durdurulduğunda ikisinin anlık görüntüsünü çıkarır.
///
/// Delegate çağrıları ayrı bir seri kuyrukta çalışır; `meshAnchors` ve `cloud`
/// yalnızca o kuyrukta okunup yazılır, @Published alanlar yalnızca main'de.
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {

    enum Phase: Equatable {
        case idle
        case scanning
        case processing
        case review
    }

    struct Stats: Equatable {
        var triangles = 0
        var vertices = 0
        var points = 0
        var cloudSaturated = false
        /// Bölge modunda kamera kutuya LiDAR'ın göremeyeceği kadar yakın.
        var tooClose = false
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var hasClassification: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    // ARView kendi ARSession'ını yaratır ve değiştirilemez, bu yüzden
    // oturumun sahibi view olmak zorunda.
    lazy var arView: ARView = {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.session.delegateQueue = work
        view.session.delegate = self
        view.renderOptions = [.disablePersonOcclusion, .disableHDR, .disableMotionBlur,
                              .disableDepthOfField, .disableFaceMesh, .disableGroundingShadows]
        return view
    }()

    var session: ARSession { arView.session }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stats = Stats()
    @Published private(set) var trackingHint: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var capturedMesh = MeshData()
    @Published private(set) var capturedCloud = CloudSnapshot()

    @Published var showMeshOverlay = true {
        didSet { applyDebugOptions() }
    }

    /// Bölge modunda taramayı sınırlayan kutu. nil ise kırpma yapılmaz.
    @Published private(set) var cropBox: CropBox?
    /// Kutunun kenar uzunluğu, metre.
    @Published var cropSize: Float = 0.4 {
        didSet {
            // Kutunun kendisi de büyüyüp küçülmeli; önceden yalnızca görsel
            // yeniden çiziliyor, boyut yerleştirildiği gibi kalıyordu.
            guard var box = cropBox else { return }
            box.size = SIMD3<Float>(repeating: cropSize)
            cropBox = box
            refreshCropBoxEntity()
        }
    }
    private(set) var kind: ScanKind = .space
    /// ARSession şu an çalışıyor mu. `stopIfRunning()` gereksiz yere ARView
    /// yaratmasın diye (arView lazy) ayrıca tutuyoruz.
    private var isSessionRunning = false

    @Published var capturePointCloud = true {
        didSet {
            let enabled = capturePointCloud
            work.async { [weak self] in self?.pointCloudEnabled = enabled }
        }
    }

    // MARK: - Yalnızca `work` kuyruğunda

    private let work = DispatchQueue(label: "com.lidarcad.session", qos: .userInitiated)
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var cloud = PointCloudAccumulator(voxelSize: 0.01, maxPoints: 4_000_000)
    private var cropBoxAnchor: AnchorEntity?
    private var pointCloudEnabled = true
    private var isCapturing = false
    private var frameCounter = 0
    private var lastStatsPush: CFAbsoluteTime = 0

    /// Mekânda ~20 Hz ve her 2. piksel yeterli; Bölge'de LiDAR'ın verdiği her
    /// pikseli 30 Hz'de alıyoruz (kutu küçük, bütçe yetiyor).
    private var depthFrameInterval = 3
    private var depthPixelStride = 2
    /// cropBox'ın work kuyruğundaki kopyası.
    private var workCropBox: CropBox?

    // MARK: - Kontrol

    func start(kind: ScanKind = .space) {
        self.kind = kind
        errorMessage = nil
        trackingHint = nil
        stats = Stats()
        removeCropBoxEntity()
        cropBox = nil

        let voxel = kind.cloudVoxelSize

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // Yumuşatılmış derinlik zamansal olarak filtrelenmiş gelir; sabit bir
        // sahneyi tararken ham derinlikten belirgin şekilde temiz.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = []
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true

        work.async { [weak self] in
            guard let self else { return }
            self.meshAnchors.removeAll()
            // Bölge modunda daha sık örnekleme istiyoruz; biriktiriciyi
            // voxel boyu değiştiğinde yeniden kuruyoruz.
            if self.cloud.voxelSize != voxel {
                self.cloud = PointCloudAccumulator(voxelSize: voxel, maxPoints: 4_000_000)
            } else {
                self.cloud.reset()
            }
            self.frameCounter = 0
            self.depthFrameInterval = kind == .region ? 2 : 3
            self.depthPixelStride = kind == .region ? 1 : 2
            self.workCropBox = nil
            self.isCapturing = true
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        applyDebugOptions()
        phase = .scanning
    }

    func finish() {
        guard phase == .scanning else { return }
        phase = .processing
        session.pause()
        isSessionRunning = false
        let box = cropBox

        work.async { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            var mesh = ARMeshExtractor.snapshot(anchors: Array(self.meshAnchors.values))
            var snapshot = self.cloud.snapshot()
            if let box {
                mesh = mesh.cropped(to: box)
                snapshot = snapshot.cropped(to: box)
            }
            DispatchQueue.main.async {
                self.capturedMesh = mesh
                self.capturedCloud = snapshot
                self.phase = .review
            }
        }
    }

    func newScan() {
        capturedMesh = MeshData()
        capturedCloud = CloudSnapshot()
        start(kind: kind)
    }

    /// Kamerayı başka bir oturuma (Object Capture) bırakmak için.
    func stopIfRunning() {
        guard isSessionRunning else { return }
        pause()
    }

    func pause() {
        session.pause()
        isSessionRunning = false
        work.async { [weak self] in self?.isCapturing = false }
        if phase == .scanning { phase = .idle }
    }

    // MARK: - Kırpma kutusu (bölge modu)

    /// Kutuyu kameranın önüne, bakış yönünde `distance` metre uzağa yerleştirir.
    func placeCropBox(distance: Float = 0.45) {
        guard let frame = session.currentFrame else {
            errorMessage = "Kamera henüz hazır değil, bir saniye bekleyin."
            return
        }
        let transform = frame.camera.transform
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // ARKit kamerası -Z yönüne bakar.
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        cropBox = CropBox(center: origin + forward * distance,
                          size: SIMD3<Float>(repeating: cropSize))
        refreshCropBoxEntity()
    }

    func clearCropBox() {
        cropBox = nil
        work.async { [weak self] in self?.workCropBox = nil }
        removeCropBoxEntity()
    }

    private func refreshCropBoxEntity() {
        let current = cropBox
        work.async { [weak self] in self?.workCropBox = current }
        removeCropBoxEntity()
        guard let cropBox else { return }

        let anchor = AnchorEntity(world: cropBox.center)
        var material = UnlitMaterial(color: .cyan)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        let box = ModelEntity(
            mesh: .generateBox(width: cropBox.size.x,
                               height: cropBox.size.y,
                               depth: cropBox.size.z),
            materials: [material])
        anchor.addChild(box)
        arView.scene.addAnchor(anchor)
        cropBoxAnchor = anchor
    }

    private func removeCropBoxEntity() {
        if let cropBoxAnchor {
            arView.scene.removeAnchor(cropBoxAnchor)
        }
        cropBoxAnchor = nil
    }

    private func applyDebugOptions() {
        arView.debugOptions = showMeshOverlay ? [.showSceneUnderstanding] : []
    }

    // MARK: - ARSessionDelegate (work kuyruğu)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        frameCounter += 1

        if pointCloudEnabled, frameCounter % depthFrameInterval == 0 {
            DepthUnprojector.accumulate(frame: frame, into: cloud,
                                        pixelStride: depthPixelStride, crop: workCropBox)
        }
        pushStatsIfNeeded(frame: frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors[anchor.identifier] = anchor
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors[anchor.identifier] = anchor
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors.removeValue(forKey: anchor.identifier)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let hint: String?
        switch camera.trackingState {
        case .normal:
            hint = nil
        case .notAvailable:
            hint = "Takip henüz başlamadı"
        case .limited(let reason):
            switch reason {
            case .initializing:
                hint = "Başlatılıyor — telefonu yavaşça sağa sola hareket ettirin"
            case .excessiveMotion:
                hint = "Çok hızlı hareket ediyorsunuz — yavaşlayın"
            case .insufficientFeatures:
                hint = "Yetersiz doku — daha aydınlık ya da desenli bir yüzeye bakın"
            case .relocalizing:
                hint = "Yeniden konumlanıyor"
            @unknown default:
                hint = "Takip sınırlı"
            }
        }
        DispatchQueue.main.async { [weak self] in self?.trackingHint = hint }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.phase = .idle
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.trackingHint = "Oturum kesintiye uğradı"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.trackingHint = nil }
    }

    // MARK: - İstatistik

    private func pushStatsIfNeeded(frame: ARFrame) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastStatsPush > 0.25 else { return }
        lastStatsPush = now

        var triangles = 0
        var vertices = 0
        for anchor in meshAnchors.values {
            triangles += anchor.geometry.faces.count
            vertices += anchor.geometry.vertices.count
        }
        var tooClose = false
        // Kare delegeden geliyor; ARView'a (UIView) bu kuyruktan dokunmuyoruz.
        if let box = workCropBox {
            let c = frame.camera.transform.columns.3
            // Kutunun en yakın yüzeyine değil merkezine bakıyoruz; yarım
            // kenar kadar pay bırakıp 30 cm sınırı koyuyoruz.
            let distance = simd_distance(SIMD3<Float>(c.x, c.y, c.z), box.center) - box.size.x * 0.5
            tooClose = distance < 0.30
        }
        let snapshot = Stats(triangles: triangles,
                             vertices: vertices,
                             points: cloud.count,
                             cloudSaturated: cloud.isSaturated,
                             tooClose: tooClose)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.stats != snapshot else { return }
            self.stats = snapshot
        }
    }
}
