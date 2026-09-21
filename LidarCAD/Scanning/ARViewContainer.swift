import SwiftUI
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let scanner: ScanSession

    func makeUIView(context: Context) -> ARView { scanner.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
