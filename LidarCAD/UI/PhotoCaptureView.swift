import SwiftUI
import AVFoundation

struct PhotoCaptureView: View {
    @ObservedObject var controller: PhotoCaptureController
    let onClose: () -> Void

    @State private var archive: URL?
    @State private var archiveError: String?
    @State private var isPacking = false
    @State private var confirmNewPass = false

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

            if case .finished(let folder) = controller.status {
                finishedOverlay(folder)
            } else {
                // Nesneyi ortada tutmak için nişangah.
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)

                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding()
            }
        }
        .onAppear {
            // Moda her girişte yeni set; önceki setler Documents/Captures'ta kalır.
            switch controller.status {
            case .configuring, .capturing: break
            default: controller.begin()
            }
        }
        .onDisappear { controller.stop() }
        .sheet(item: $archive) { url in ShareSheet(urls: [url]) }
    }

    // MARK: - Üst

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .cancel, action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                Spacer()
                HStack(spacing: 10) {
                    Label("Tur \(controller.pass + 1)", systemImage: "arrow.triangle.2.circlepath")
                    Text("\(controller.shotsInPass)/\(controller.recommendedPerPass)")
                        .monospacedDigit()
                        .foregroundStyle(controller.shotsInPass >= controller.recommendedPerPass ? .green : .primary)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if !controller.depthEnabled, controller.status != .configuring {
                pill("LiDAR derinliği yok — ölçek Mac'te tahmini olur", icon: "exclamationmark.triangle.fill", tint: .orange)
            }
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch controller.status {
        case .idle, .configuring:
            pill("Kamera hazırlanıyor…", icon: "camera", tint: .secondary)
        case .ready:
            pill(controller.shotCount == 0
                 ? "Nesneyi ortaya koyun, elinizi çekin"
                 : "Nesneyi 10° çevirin, elinizi çekin",
                 icon: "hand.raised", tint: .primary)
        case .moving:
            pill("Hareket var — elinizi çekin", icon: "hand.wave", tint: .yellow)
        case .settling(let p):
            pill("Duruluyor… %\(Int(p * 100))", icon: "timer", tint: .cyan)
        case .capturing:
            pill("Çekiliyor", icon: "camera.shutter.button", tint: .green)
        case .failed(let message):
            pill(message, icon: "xmark.octagon.fill", tint: .red)
        case .finished:
            EmptyView()
        }
    }

    // MARK: - Alt

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if controller.shotCount == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Telefonu sabitleyin, nesne çerçeveyi doldursun", systemImage: "iphone.gen3")
                    Label("Işık dağınık olsun: pencere ya da tavan ışığı. Tek yönlü sert lamba, nesne döndükçe gölgeyi kaydırır ve modeli bozar", systemImage: "lightbulb")
                    Label("Her seferinde ~10° döndürün, elinizi çekin — durulunca kendiliğinden çeker. Döndürdükten sonra hiçbir düğmeye basmayın", systemImage: "rotate.right")
                    Label("Bir tur ~36 fotoğraf. Tur bitince nesneyi yan yatırın ve \"Yan yatırdım\" deyin", systemImage: "arrow.uturn.down")
                }
                    .font(.caption)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(alignment: .center, spacing: 18) {
                // Son çekim önizlemesi
                Group {
                    if let thumb = controller.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.black.opacity(0.4)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                Button {
                    controller.capture()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 68, height: 68)
                        Circle().strokeBorder(.black.opacity(0.2), lineWidth: 3).frame(width: 60, height: 60)
                    }
                }
                .disabled(!canShoot)

                Spacer()

                Toggle(isOn: $controller.autoCapture) {
                    Image(systemName: "a.circle")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .frame(width: 54)
            }

            HStack(spacing: 10) {
                // "Çevirdim" hem döndürmek hem ters çevirmek demek; kullanıcı her
                // 10°'de basıyordu. Bu düğme yalnızca nesne yan yatırılınca.
                Button {
                    if controller.shotsInPass < 12 { confirmNewPass = true } else { controller.startNewPass() }
                } label: {
                    Label("Yan yatırdım — yeni tur", systemImage: "arrow.uturn.down")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(controller.shotsInPass == 0)
                .confirmationDialog("Bu turda sadece \(controller.shotsInPass) fotoğraf var",
                                    isPresented: $confirmNewPass, titleVisibility: .visible) {
                    Button("Evet, nesneyi yan yatırdım") { controller.startNewPass() }
                    Button("Hayır, sadece döndürdüm", role: .cancel) {}
                } message: {
                    Text("Bu düğme nesneyi yan yatırdığınızda, alt yüzünü göstermek için. Sadece döndürdüyseniz basmanıza gerek yok; çekim kendiliğinden devam eder.")
                }

                Button {
                    controller.finish()
                } label: {
                    Label("Bitir", systemImage: "checkmark").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.shotCount < 3)
            }
        }
    }

    private var canShoot: Bool {
        switch controller.status {
        case .ready, .moving, .settling: return true
        default: return false
        }
    }

    // MARK: - Bitti

    private func finishedOverlay(_ folder: URL) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.green)
                Text("\(controller.shotCount) fotoğraf, \(controller.pass + 1) tur")
                    .font(.title3.bold())
                Text(folder.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    isPacking = true
                    Task {
                        defer { isPacking = false }
                        do { archive = try controller.makeArchive() }
                        catch { archiveError = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        if isPacking { ProgressView().controlSize(.small) }
                        Label("AirDrop ile Mac'e gönder", systemImage: "square.and.arrow.up")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPacking)

                if let archiveError {
                    Text(archiveError).font(.caption).foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac'te:").font(.caption.bold())
                    Text("~/LidarCAD/mac/build/lidarcad-reconstruct ~/Downloads/\(folder.lastPathComponent).zip")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Text("Kesit isterseniz sonuna  --sections 0.02,0.05  ekleyin (metre).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button("Yeni set") { controller.begin() }
                        .buttonStyle(.bordered)
                    Button("Modlara dön", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
    }

    private func pill(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// AVCaptureSession önizlemesi.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // Kırpmadan göster: kullanıcı fotoğrafa gerçekte neyin gireceğini görsün.
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
