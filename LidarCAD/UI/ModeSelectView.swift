import SwiftUI

struct ModeSelectView: View {
    let onSelect: (ScanKind) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("LidarCAD")
                    .font(.largeTitle.bold())
                Text("Tarama sonucunu Fusion 360'a hazır hale getirir")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 14) {
                ForEach(ScanKind.allCases) { kind in
                    Button {
                        onSelect(kind)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 30))
                                .frame(width: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title)
                                    .font(.headline)
                                Text(kind.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable(kind))
                    .opacity(isAvailable(kind) ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 20)

            if !ObjectCaptureController.isSupported {
                Text("Nesne taraması bu cihazda desteklenmiyor.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Text("Nesne modu fotogrametri kullanır: nesnenin dokulu olması ve ortamın iyi aydınlatılmış olması gerekir. Parlak metal, cam ve düz beyaz yüzeyler çıkmaz.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
        }
    }

    private func isAvailable(_ kind: ScanKind) -> Bool {
        switch kind {
        case .space, .region: return ScanSession.isSupported
        case .object:         return ObjectCaptureController.isSupported
        }
    }
}
