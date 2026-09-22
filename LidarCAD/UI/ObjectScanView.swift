import SwiftUI
import RealityKit

struct ObjectScanView: View {
    @ObservedObject var controller: ObjectCaptureController
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            if let session = controller.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()

            if case .reconstructing(let progress) = controller.stage {
                reconstructionOverlay(progress)
            }
            if case .finishing = controller.stage {
                busyOverlay("Çekim tamamlanıyor…")
            }
        }
    }

    // MARK: - Üst

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .cancel, action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                Spacer()
                if controller.maximumShots > 0, isCapturing {
                    Text("\(controller.shotsTaken) / \(controller.maximumShots)")
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            ForEach(feedbackMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var feedbackMessages: [String] {
        controller.feedback.compactMap(\.message).sorted()
    }

    private var isCapturing: Bool {
        if case .capturing = controller.stage { return true }
        return false
    }

    // MARK: - Alt

    @ViewBuilder
    private var bottomBar: some View {
        switch controller.stage {
        case .idle:
            hint("Hazırlanıyor…")

        case .ready:
            VStack(spacing: 12) {
                hint("Nesneyi ekranın ortasına alın, 20–80 cm mesafede durun.")
                primary("Nesneyi algıla", icon: "viewfinder") { controller.startDetecting() }
            }

        case .detecting:
            VStack(spacing: 12) {
                hint("Kutu nesneyi tam sarmalıyor mu? Gerekirse kutuyu sürükleyerek ayarlayın.")
                primary("Taramayı başlat", icon: "record.circle") { controller.startCapturing() }
            }

        case .capturing:
            VStack(spacing: 12) {
                if controller.completedPass {
                    hint("Tur tamamlandı. Nesneyi ters çevirip devam ederseniz alt yüzeyi de modele girer.")
                    HStack(spacing: 10) {
                        secondary("Çevirdim, devam", icon: "arrow.triangle.2.circlepath") {
                            controller.beginNewPassAfterFlip()
                        }
                        secondary("Yeni tur", icon: "arrow.clockwise") {
                            controller.beginNewPass()
                        }
                    }
                    primary("Bitir ve modeli oluştur", icon: "checkmark") { controller.finish() }
                } else {
                    hint("Nesnenin etrafında yavaşça tam tur atın. Yükseklik değiştirmeyi unutmayın.")
                }
            }

        case .finishing, .reconstructing, .done:
            EmptyView()

        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                primary("Yeniden dene", icon: "arrow.clockwise") { controller.begin() }
            }
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

    private func busyOverlay(_ title: String) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(title).font(.headline)
            }
        }
    }

    private func reconstructionOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("Model oluşturuluyor — %\(Int(progress * 100))")
                    .font(.headline.monospacedDigit())
                Text("Fotoğraf sayısına göre birkaç dakika sürebilir. Uygulamayı kapatmayın.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}
