import Accelerate
import CoreImage
import CoreVideo

/// Cheap per-frame metrics computed on a small greyscale thumbnail.
struct FrameMetrics: Sendable {
    /// Variance of a 3×3 Laplacian — higher is sharper. Typical: <40 blurry, >120 sharp.
    var sharpness: Double
    /// Mean absolute difference vs the previous thumbnail (0–255). <3 is still.
    var motion: Double
    /// Mean absolute difference vs the "empty scene" baseline. >18 means something is in frame.
    var sceneDelta: Double
    /// 64-bit perceptual hash of the thumbnail (8×8 average hash) for "same item?" checks.
    var hash: UInt64
}

/// Turns raw BGRA frames into small greyscale planes and computes the metrics above.
/// Not thread-safe; owned by the capture engine's actor.
final class FrameAnalyzer {
    let width = 96, height = 72
    private var previous: [UInt8]?
    private var baseline: [UInt8]?
    private var lastHash: UInt64?

    func resetBaseline() { baseline = nil }
    func hasBaseline() -> Bool { baseline != nil }

    /// Adopt the current frame as the "nothing in front of the camera" reference.
    func setBaseline(from grey: [UInt8]) { baseline = grey }

    func greyscale(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let srcW = CVPixelBufferGetWidth(pixelBuffer), srcH = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [UInt8](repeating: 0, count: width * height) }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        // Only the central region (the alignment guide) is analysed: hands entering at the edges don't count.
        let cx0 = srcW * 15 / 100, cy0 = srcH * 12 / 100
        let cw = srcW * 70 / 100, ch = srcH * 76 / 100
        // Box-sample: average a small block per output pixel, luma from BGRA.
        let bx = max(1, cw / width), by = max(1, ch / height)
        for y in 0..<height {
            let sy0 = cy0 + y * ch / height
            for x in 0..<width {
                let sx0 = cx0 + x * cw / width
                var sum = 0, n = 0
                var yy = sy0
                while yy < min(srcH, sy0 + by) {
                    var xx = sx0
                    let row = src + yy * stride
                    while xx < min(srcW, sx0 + bx) {
                        let p = row + xx * 4
                        // BGRA → luma (Rec. 601, integer weights)
                        sum += (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
                        n += 1; xx += 2
                    }
                    yy += 2
                }
                out[y * width + x] = UInt8(clamping: n == 0 ? 0 : sum / n)
            }
        }
        return out
    }

    func analyze(_ grey: [UInt8]) -> FrameMetrics {
        let sharp = laplacianVariance(grey)
        let motion = previous.map { meanAbsDiff($0, grey) } ?? 255
        let scene = baseline.map { meanAbsDiff($0, grey) } ?? 255
        let hash = averageHash(grey)
        previous = grey
        lastHash = hash
        return FrameMetrics(sharpness: sharp, motion: motion, sceneDelta: scene, hash: hash)
    }

    private func laplacianVariance(_ g: [UInt8]) -> Double {
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let l = Double(Int(g[i]) * 4 - Int(g[i - 1]) - Int(g[i + 1]) - Int(g[i - width]) - Int(g[i + width]))
                sum += l; sumSq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in 0..<min(a.count, b.count) { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    private func averageHash(_ g: [UInt8]) -> UInt64 {
        // Downsample to 8×8 by block averaging, then threshold on the mean.
        var cells = [Int](repeating: 0, count: 64)
        let cw = width / 8, ch = height / 8
        for cy in 0..<8 {
            for cx in 0..<8 {
                var s = 0
                for y in (cy * ch)..<((cy + 1) * ch) { for x in (cx * cw)..<((cx + 1) * cw) { s += Int(g[y * width + x]) } }
                cells[cy * 8 + cx] = s / (cw * ch)
            }
        }
        let mean = cells.reduce(0, +) / 64
        var h: UInt64 = 0
        for (i, c) in cells.enumerated() where c > mean { h |= 1 << UInt64(i) }
        return h
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
