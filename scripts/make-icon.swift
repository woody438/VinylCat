// Draws the VinylCat app icon — a plain black record, burnt-orange label, two fine whiskers a side:
// the design from Woody's 2026-09-07 logo chat; `Support/LogoMark.swift` draws the same geometry
// in SwiftUI for the top bar — and writes
// Resources/AppIcon.icns plus a 1024 preview PNG. No Xcode, no asset catalogue:
//   swift scripts/make-icon.swift
// Colours are Theme's (design/mockups/build.mjs, direction A).
import AppKit
import CoreGraphics
import Foundation

let bg = CGColor(red: 0x0E / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
let panel = CGColor(red: 0x1B / 255, green: 0x1F / 255, blue: 0x23 / 255, alpha: 1)
let orange = CGColor(red: 0xCC / 255, green: 0x6A / 255, blue: 0x3C / 255, alpha: 1)      // burnt orange (LogoGeometry.burntOrange)
let orangeDeep = CGColor(red: 0x9E / 255, green: 0x4F / 255, blue: 0x2A / 255, alpha: 1)
let disc = CGColor(red: 0x0E / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
let cream = CGColor(red: 0xF2 / 255, green: 0xEF / 255, blue: 0xE8 / 255, alpha: 1)

func draw(size: CGFloat, plate: Bool = true) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work y-down, like the SwiftUI `LogoGeometry`, so the two renderers share numbers.
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

    if plate {
        // Rounded-square plate, inset like a standard macOS icon; a flat, slightly lifted charcoal.
        let inset = size * 56 / 1024
        let plateRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let corner = size * 205 / 1024
        ctx.addPath(CGPath(roundedRect: plateRect, cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.clip()
        ctx.setFillColor(panel); ctx.fill(plateRect)
    }

    // The mark, on the inner 78% of the plate. Same numbers as LogoGeometry.
    let markSize = plate ? size * 0.78 : size
    let origin = (size - markSize) / 2
    let c = CGPoint(x: origin + markSize * 0.5, y: origin + markSize * 0.5)
    let r = markSize * 0.46
    let labelR = r * 0.30, holeR = r * 0.035

    // Flat black disc, grooves barely there.
    ctx.setFillColor(disc)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.setLineWidth(max(0.5, markSize * 0.006)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.05))
    for i in 0..<3 { let rr = r * (0.60 + CGFloat(i) * 0.12); ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)) }

    // Burnt-orange label with a thin deeper rim, and the spindle hole.
    ctx.setFillColor(orange); ctx.fillEllipse(in: CGRect(x: c.x - labelR, y: c.y - labelR, width: labelR * 2, height: labelR * 2))
    ctx.setStrokeColor(orangeDeep); ctx.setLineWidth(max(0.5, markSize * 0.008))
    ctx.strokeEllipse(in: CGRect(x: c.x - labelR, y: c.y - labelR, width: labelR * 2, height: labelR * 2))
    ctx.setFillColor(disc); ctx.fillEllipse(in: CGRect(x: c.x - holeR, y: c.y - holeR, width: holeR * 2, height: holeR * 2))

    // Two fine whiskers a side, splayed 7° and bowed a touch outward.
    ctx.setStrokeColor(cream); ctx.setLineWidth(max(0.6, markSize * 0.0075)); ctx.setLineCap(.round)
    for side in [CGFloat(-1), 1] {
        for (lift, angle) in [(CGFloat(0.13), CGFloat(7)), (CGFloat(-0.13), CGFloat(-7))] {
            let x0 = c.x + side * (labelR + r * 0.10), y0 = c.y - lift * labelR
            let len = r * 0.55, a = angle * .pi / 180
            let x1 = x0 + side * len * cos(a), y1 = y0 - len * sin(a)
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2 - (lift > 0 ? 1 : -1) * r * 0.035
            ctx.move(to: CGPoint(x: x0, y: y0)); ctx.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy)); ctx.strokePath()
        }
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (px, names) in [(16, ["icon_16x16"]), (32, ["icon_16x16@2x", "icon_32x32"]), (64, ["icon_32x32@2x"]),
                    (128, ["icon_128x128"]), (256, ["icon_128x128@2x", "icon_256x256"]),
                    (512, ["icon_256x256@2x", "icon_512x512"]), (1024, ["icon_512x512@2x"])] {
    let img = draw(size: CGFloat(px))
    for n in names { try writePNG(img, to: iconset.appendingPathComponent("\(n).png")) }
}
try writePNG(draw(size: 1024), to: root.appendingPathComponent("build/AppIcon-1024.png"))
try writePNG(draw(size: 512, plate: false), to: root.appendingPathComponent("build/Logo-512.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and build/AppIcon-1024.png" : "iconutil failed (\(p.terminationStatus))")
