import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var scanner = ScanSession()

    var body: some View {
        Group {
            if ScanSession.isSupported {
                switch scanner.phase {
                case .idle, .scanning, .processing:
                    ScanView(scanner: scanner)
                case .review:
                    ExportView(scanner: scanner)
                }
            } else {
                UnsupportedView()
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("LiDAR bulunamadı")
                .font(.title2.bold())
            Text("Bu uygulama LiDAR tarayıcılı bir cihaz gerektirir: iPhone 12 Pro ve sonrası Pro/Pro Max modelleri veya iPad Pro 2020+.\n\nSimülatörde çalışmaz — gerçek cihazda deneyin.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

/// Sayıları binlik ayraçla gösterir (12.483 gibi).
func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = "."
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}
