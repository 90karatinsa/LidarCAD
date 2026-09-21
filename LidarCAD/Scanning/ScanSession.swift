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

    @Published var capturePointCloud = true {
        didSet {
            let enabled = capturePointCloud
            work.async { [weak self] in self?.pointCloudEnabled = enabled }
        }
    }

    // MARK: - Yalnızca `work` kuyruğunda

    private let work = DispatchQueue(label: "com.lidarcad.session", qos: .userInitiated)
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private let cloud = PointCloudAccumulator(voxelSize: 0.01, maxPoints: 4_000_000)
    private var pointCloudEnabled = true
    private var isCapturing = false
    private var frameCounter = 0
    private var lastStatsPush: CFAbsoluteTime = 0

    /// Her karede derinlik açmak gereksiz; ~20 Hz yeterli ve batarya dostu.
    private let depthFrameInterval = 3

    // MARK: - Kontrol

    func start() {
        errorMessage = nil
        trackingHint = nil
        stats = Stats()

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
            self.cloud.reset()
            self.frameCounter = 0
            self.isCapturing = true
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyDebugOptions()
        phase = .scanning
    }

    func finish() {
        guard phase == .scanning else { return }
        phase = .processing
        session.pause()

        work.async { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            let mesh = ARMeshExtractor.snapshot(anchors: Array(self.meshAnchors.values))
            let snapshot = self.cloud.snapshot()
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
        start()
    }

    func pause() {
        session.pause()
        work.async { [weak self] in self?.isCapturing = false }
        if phase == .scanning { phase = .idle }
    }

    private func applyDebugOptions() {
        arView.debugOptions = showMeshOverlay ? [.showSceneUnderstanding] : []
    }

    // MARK: - ARSessionDelegate (work kuyruğu)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        frameCounter += 1

        if pointCloudEnabled, frameCounter % depthFrameInterval == 0 {
            DepthUnprojector.accumulate(frame: frame, into: cloud, pixelStride: 2)
        }
        pushStatsIfNeeded()
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

    private func pushStatsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastStatsPush > 0.25 else { return }
        lastStatsPush = now

        var triangles = 0
        var vertices = 0
        for anchor in meshAnchors.values {
            triangles += anchor.geometry.faces.count
            vertices += anchor.geometry.vertices.count
        }
        let snapshot = Stats(triangles: triangles,
                             vertices: vertices,
                             points: cloud.count,
                             cloudSaturated: cloud.isSaturated)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.stats != snapshot else { return }
            self.stats = snapshot
        }
    }
}
