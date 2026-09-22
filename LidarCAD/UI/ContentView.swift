import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var scanner = ScanSession()
    @StateObject private var objectCapture = ObjectCaptureController()
    @State private var kind: ScanKind?

    var body: some View {
        Group {
            switch kind {
            case nil:
                ModeSelectView { selected in
                    kind = selected
                    switch selected {
                    case .space, .region: scanner.start(kind: selected)
                    case .object:         objectCapture.begin()
                    }
                }

            case .space, .region:
                switch scanner.phase {
                case .idle, .scanning, .processing:
                    ScanView(scanner: scanner, onCancel: backToModes)
                case .review:
                    ExportView(mesh: scanner.capturedMesh,
                               cloud: scanner.capturedCloud,
                               kind: scanner.kind,
                               onNewScan: { scanner.newScan() },
                               onChangeMode: backToModes)
                }

            case .object:
                if case .done = objectCapture.stage {
                    ExportView(mesh: objectCapture.mesh,
                               cloud: CloudSnapshot(),
                               kind: .object,
                               onNewScan: { objectCapture.begin() },
                               onChangeMode: backToModes)
                } else {
                    ObjectScanView(controller: objectCapture, onCancel: backToModes)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func backToModes() {
        scanner.pause()
        objectCapture.cancel()
        kind = nil
    }
}

/// Sayıları binlik ayraçla gösterir (12.483 gibi).
func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = "."
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}
