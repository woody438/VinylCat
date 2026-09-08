// Draws the VinylCat app icon — a record that is also a cat's head (ears above the disc, burnt-orange
// label), the design from Woody's 2026-09-07 logo chat; `Support/LogoMark.swift` draws the same
// geometry in SwiftUI for the top bar — and writes
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
let disc = CGColor(red: 0x0A / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)

func draw(size: CGFloat, plate: Bool = true) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work y-down, like the SwiftUI `LogoGeometry`, so the two renderers share numbers.
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

    if plate {
        // Rounded-square plate, inset like a standard macOS icon.
        let inset = size * 56 / 1024
        let plateRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let corner = size * 205 / 1024
        ctx.addPath(CGPath(roundedRect: plateRect, cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [panel, bg] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
    }

    // The mark, on the inner 80% of the plate.
    let markSize = plate ? size * 0.80 : size
    let origin = (size - markSize) / 2
    let c = CGPoint(x: origin + markSize * 0.5, y: origin + markSize * 0.56)
    let r = markSize * 0.40
    func point(_ deg: CGFloat, _ radius: CGFloat) -> CGPoint { let a = deg * .pi / 180; return CGPoint(x: c.x + radius * cos(a), y: c.y - radius * sin(a)) }

    // Ears: triangular with a softened tip, base on the disc's edge (same angles as LogoGeometry.ear).
    ctx.setFillColor(disc)
    for left in [true, false] {
        let a0: CGFloat = left ? 113 : 67, a1: CGFloat = left ? 151 : 29, tipA: CGFloat = left ? 128 : 52
        let b0 = point(a0, r * 0.98), b1 = point(a1, r * 0.98), tip = point(tipA, r * 1.58)
        let k: CGFloat = 0.14
        let t0 = CGPoint(x: tip.x + (b0.x - tip.x) * k, y: tip.y + (b0.y - tip.y) * k)
        let t1 = CGPoint(x: tip.x + (b1.x - tip.x) * k, y: tip.y + (b1.y - tip.y) * k)
        ctx.move(to: b0); ctx.addLine(to: t0); ctx.addQuadCurve(to: t1, control: tip); ctx.addLine(to: b1); ctx.closePath(); ctx.fillPath()
    }

    // The record: near-black disc with a faint sheen and grooves.
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: c.x - r, y: c.y - r), end: CGPoint(x: c.x + r * 0.4, y: c.y + r), options: [])
    ctx.setLineWidth(max(0.6, markSize * 0.012)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    for i in 0..<5 { let rr = r * (0.52 + CGFloat(i) * 0.09); ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)) }
    ctx.restoreGState()

    // Burnt-orange label with a deeper rim, and the spindle hole.
    let R = r * 0.36
    ctx.setFillColor(orange); ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.setStrokeColor(orangeDeep); ctx.setLineWidth(max(0.6, markSize * 0.018))
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    let hole = r * 0.05
    ctx.setFillColor(disc); ctx.fillEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
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
