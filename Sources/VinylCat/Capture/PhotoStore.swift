import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes captured stills as JPEGs under ~/Library/Application Support/VinylCat/Photos/.
struct PhotoStore: Sendable {
    let root: URL

    static let shared = PhotoStore()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = appSupport.appendingPathComponent("VinylCat/Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Saves `image` downscaled so its longest side is `maxSide`, returns the file URL.
    func save(_ image: CGImage, name: String, maxSide: Int = 1600, quality: Double = 0.85) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("jpg")
        let scaled = downscale(image, maxSide: maxSide) ?? image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func downscale(_ image: CGImage, maxSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxSide else { return image }
        let s = Double(maxSide) / Double(longest)
        let nw = Int(Double(w) * s), nh = Int(Double(h) * s)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
