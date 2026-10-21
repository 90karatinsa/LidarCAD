import SwiftUI
import RealityKit
import Combine

struct ObjectScanView: View {
    @ObservedObject var controller: ObjectCaptureController
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            if let session = controller.session {
                CaptureLayer(session: session, controller: controller, onCancel: onCancel)
            } else {
                Color.black.ignoresSafeArea()
            }

            switch controller.phase {
            case .reconstructing(let progress):
                reconstructionOverlay(progress)
            case .failed(let message):
                failedOverlay(message)
            case .capturing, .done:
                EmptyView()
            }
        }
    }

    private func reconstructionOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("Model oluşturuluyor — %\(Int(progress * 100))")
                    .font(.headline.monospacedDigit())
                Text("Fotoğraf sayısına göre birkaç dakika sürebilir. Uygulamayı kapatmayın, ekranı kilitlemeyin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private func failedOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                HStack(spacing: 12) {
                    Button("Modlara dön", action: onCancel)
                        .buttonStyle(.bordered)
                    Button("Yeniden dene") { controller.begin() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Canlı çekim katmanı. `ObjectCaptureSession` @Observable olduğu için
/// `session.state`, `session.feedback` vb. okumaları body içinde otomatik izlenir.
private struct CaptureLayer: View {
    let session: ObjectCaptureSession
    @ObservedObject var controller: ObjectCaptureController
    let onCancel: () -> Void

    @State private var stateChangedAt = Date()
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()

            if case .finishing = session.state {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Çekim tamamlanıyor…").font(.headline)
                    }
                }
            }
        }
        .onChange(of: session.state, initial: true) { _, newState in
            stateChangedAt = Date()
            controller.sync(newState)
        }
        .onChange(of: session.userCompletedScanPass) { _, completed in
            if !completed { controller.passDidReset() }
        }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Üst

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .cancel, action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                Spacer()
                if case .capturing = session.state {
                    Text("\(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages)")
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            ForEach(session.feedback.compactMap(\.message).sorted(), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    // MARK: - Alt

    @ViewBuilder
    private var bottomBar: some View {
        switch session.state {
        case .initializing:
            VStack(spacing: 8) {
                hint("Hazırlanıyor…")
                // 6 saniyeden uzun sürüyorsa ne olduğunu göster — körlemesine
                // beklemek yerine sorunu raporlayabilmek için.
                if now.timeIntervalSince(stateChangedAt) > 6 {
                    Text("Durum: \(session.state.label) · Takip: \(session.cameraTracking.label)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    hint("Uzun sürüyorsa telefonu yavaşça sağa sola oynatın. Hâlâ ilerlemezse uygulamayı tamamen kapatıp yeniden açın.")
                }
            }

        case .ready:
            VStack(spacing: 12) {
                hint("Nesneyi ekranın ortasına alın, 20–80 cm mesafede durun.")
                primary("Nesneyi algıla", icon: "viewfinder") { controller.startDetecting() }
            }

        case .detecting:
            VStack(spacing: 12) {
                hint("Kutu nesneyi tam sarmalıyor mu? Gerekirse köşelerinden sürükleyerek ayarlayın.")
                primary("Taramayı başlat", icon: "record.circle") { controller.startCapturing() }
            }

        case .capturing:
            VStack(spacing: 12) {
                if session.userCompletedScanPass {
                    let flippable = !session.feedback.contains(.objectNotFlippable)
                    hint(flippable
                         ? "Tur tamamlandı. Nesneyi ters çevirip devam ederseniz alt yüzeyi de modele girer."
                         : "Tur tamamlandı. Bu nesne çevrilmeye uygun değil — farklı yükseklikten bir tur daha atabilir ya da bitirebilirsiniz.")
                    HStack(spacing: 10) {
                        if flippable {
                            secondary("Çevirdim, devam", icon: "arrow.triangle.2.circlepath") {
                                controller.beginNewPassAfterFlip()
                            }
                            .disabled(!controller.canFlip(session))
                        }
                        secondary("Yeni tur", icon: "arrow.clockwise") {
                            controller.beginNewPass()
                        }
                        .disabled(!controller.canStartNewPass(session))
                    }
                    primary("Bitir ve modeli oluştur", icon: "checkmark") { controller.finish() }
                        .disabled(controller.passTransitionPending)
                } else {
                    hint("Nesnenin etrafında yavaşça tam tur atın. Arada yükseklik değiştirin.")
                }
            }

        case .finishing, .completed, .failed:
            EmptyView()

        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Parçalar

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
    }

    private func primary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func secondary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.footnote)
        }
        .buttonStyle(.bordered)
    }
}
