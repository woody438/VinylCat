import AVFoundation
import SwiftUI

/// Live camera preview backed by AVCaptureVideoPreviewLayer.
struct CameraPreviewView: NSViewRepresentable {
    let box: CaptureBox

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.previewLayer.session = box.session
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.backgroundColor = NSColor(Theme.panel).cgColor
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
