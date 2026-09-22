import SwiftUI

struct ScanView: View {
    @ObservedObject var scanner: ScanSession
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ARViewContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()

            if scanner.phase == .processing {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Tarama işleniyor…")
                        .font(.headline)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scanner.phase)
        // ARView kendi oturumunu kurmuyor (automaticallyConfigureSession = false),
        // bu yüzden görünür olur olmaz başlatmazsak ekran siyah kalır.
        .onAppear { if scanner.phase == .idle { scanner.start() } }
    }

    // MARK: - Üst

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .cancel, action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                Spacer()
                Text(scanner.kind.title)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if scanner.phase == .scanning {
                HStack(spacing: 14) {
                    stat("triangle", grouped(scanner.stats.triangles), "üçgen")
                    if scanner.capturePointCloud {
                        stat("circle.dotted", grouped(scanner.stats.points), "nokta")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }

            if let hint = scanner.trackingHint {
                label(hint, systemImage: "exclamationmark.circle.fill", tint: .orange)
            }
            if scanner.stats.cloudSaturated {
                label("Nokta bulutu üst sınırda — mesh toplanmaya devam ediyor",
                      systemImage: "externaldrive.fill", tint: .yellow)
            }
            if let error = scanner.errorMessage {
                label(error, systemImage: "xmark.octagon.fill", tint: .red)
            }
        }
    }

    private func stat(_ symbol: String, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption)
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).font(.footnote)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .multilineTextAlignment(.center)
    }

    // MARK: - Alt

    @ViewBuilder
    private var bottomBar: some View {
        switch scanner.phase {
        case .idle, .scanning:
            VStack(spacing: 12) {
                if scanner.stats.triangles == 0 {
                    Text(scanner.kind == .region
                         ? "Yuvayı kadraja alın, kutuyu yerleştirin ve sadece o bölgeyi yavaşça tarayın."
                         : "Telefonu yüzeyden 0,5–5 m uzakta tutun, yavaş hareket edin ve tur atıp başladığınız noktaya dönün.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                }

                if scanner.kind == .region { cropBoxControls }

                HStack(spacing: 10) {
                    Toggle(isOn: $scanner.showMeshOverlay) {
                        Label("Mesh", systemImage: "grid")
                    }
                    Toggle(isOn: $scanner.capturePointCloud) {
                        Label("Nokta bulutu", systemImage: "circle.dotted")
                    }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .font(.footnote)

                Button {
                    scanner.finish()
                } label: {
                    Label("Bitir", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(scanner.stats.triangles == 0
                          || (scanner.kind == .region && scanner.cropBox == nil))
            }
            .padding(.bottom, 8)

        case .processing, .review:
            EmptyView()
        }
    }

    // MARK: - Kırpma kutusu (bölge modu)

    @ViewBuilder
    private var cropBoxControls: some View {
        VStack(spacing: 8) {
            if scanner.cropBox == nil {
                Text("Kutuyu yuvanın ortasına doğrultup yerleştirin — dışında kalan her şey atılır.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    scanner.placeCropBox()
                } label: {
                    Label("Kutuyu yerleştir", systemImage: "viewfinder.rectangular")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            } else {
                HStack(spacing: 10) {
                    Text("Kutu").font(.caption)
                    Slider(value: $scanner.cropSize, in: 0.1...1.5, step: 0.05)
                    Text("\(Int(scanner.cropSize * 100)) cm")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    Button {
                        scanner.placeCropBox()
                    } label: {
                        Label("Yeniden konumla", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        scanner.clearCropBox()
                    } label: {
                        Label("Kaldır", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
