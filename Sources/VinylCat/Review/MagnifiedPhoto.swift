import AppKit
import SwiftUI

/// A scan photo with a loupe: move the pointer over it and a circle follows, showing the pixels
/// under the cursor at (close to) native resolution so a catalogue number or matrix can be read
/// off a shot the readers couldn't. Photos are 1600×900, shown at ~440 wide, so the loupe runs
/// at roughly 3.5× — anything more would just blur.
struct MagnifiedPhoto: View {
    let url: URL?
    var width: CGFloat = 440
    var maxHeight: CGFloat = 440
    var loupe: CGFloat = 260
    @State private var image: NSImage?
    @State private var pixels = CGSize(width: 16, height: 9)
    @State private var pointer: CGPoint?

    var body: some View {
        let fit = fitSize
        ZStack(alignment: .topLeading) {
            Theme.panel
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                if let p = pointer {
                    let zoom = min(4, max(2, pixels.width / fit.width))
                    // topLeading alignment on the outer frame is what makes the offset maths hold:
                    // a centred child would put the pixels under the cursor somewhere else entirely.
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: fit.width * zoom, height: fit.height * zoom)
                        .offset(x: loupe / 2 - p.x * zoom, y: loupe / 2 - p.y * zoom)
                        .frame(width: loupe, height: loupe, alignment: .topLeading)
                    .background(Theme.bg)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.green, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                    .position(p)
                    .allowsHitTesting(false)
                }
            } else {
                Caption("NO PHOTO").padding(16)
            }
        }
        .frame(width: fit.width, height: fit.height)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): pointer = p
            case .ended: pointer = nil
            }
        }
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        .task(id: url) {
            pointer = nil
            guard let url, let img = NSImage(contentsOf: url) else { image = nil; return }
            image = img
            if let rep = img.representations.first, rep.pixelsWide > 0 {
                pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            } else {
                pixels = img.size
            }
        }
    }

    /// Displayed size: full width, height from the photo's aspect, capped for portrait shots.
    private var fitSize: CGSize {
        let h = width * pixels.height / pixels.width
        if h <= maxHeight { return CGSize(width: width, height: h) }
        return CGSize(width: maxHeight * pixels.width / pixels.height, height: maxHeight)
    }
}
