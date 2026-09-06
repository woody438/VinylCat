// Draws the VinylCat app icon (a record with a cat sitting in the label) and writes
// Resources/AppIcon.icns plus a 1024 preview PNG. No Xcode, no asset catalogue:
//   swift scripts/make-icon.swift
// Colours are Theme's (design/mockups/build.mjs, direction A).
import AppKit
import CoreGraphics
import Foundation

let bg = CGColor(red: 0x0E / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
let panel = CGColor(red: 0x1B / 255, green: 0x1F / 255, blue: 0x23 / 255, alpha: 1)
let orange = CGColor(red: 0xF2 / 255, green: 0x8B / 255, blue: 0x5C / 255, alpha: 1)
let orangeDeep = CGColor(red: 0xC7 / 255, green: 0x6A / 255, blue: 0x42 / 255, alpha: 1)
let disc = CGColor(red: 0x0A / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)

func draw(size: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size / 1024                       // everything below is authored at 1024
    func p(_ v: CGFloat) -> CGFloat { v * s }

    // Rounded-square plate, inset like a standard macOS icon.
    let plate = CGRect(x: p(56), y: p(56), width: p(912), height: p(912))
    let plated = CGPath(roundedRect: plate, cornerWidth: p(205), cornerHeight: p(205), transform: nil)
    ctx.addPath(plated); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [panel, bg] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

    let c = CGPoint(x: size / 2, y: size / 2)
    let discR = p(380)

    // The record: near-black disc with a faint sheen and a few grooves.
    ctx.setFillColor(disc)
    ctx.fillEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
    ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: c.x - discR, y: c.y + discR), end: CGPoint(x: c.x + discR * 0.4, y: c.y - discR), options: [])
    ctx.setLineWidth(max(0.6, p(3)))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
    for i in 0..<9 {
        let r = discR * (0.46 + CGFloat(i) * 0.06)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()

    // The label.
    let R = discR * 0.44
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.setStrokeColor(orangeDeep); ctx.setLineWidth(max(0.6, p(6)))
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))

    // The cat, knocked out of the label. Label space: origin at c, +y up, unit = R.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.clip()
    ctx.setFillColor(bg)
    ctx.setStrokeColor(bg)
    // Sit the cat wholly inside the label rather than letting the label edge slice its base off.
    ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 0.84, y: 0.84); ctx.translateBy(x: -c.x, y: -c.y + R * 0.10)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * R, y: c.y + y * R) }

    // Tail, curling out to the right of the body.
    ctx.setLineWidth(R * 0.15); ctx.setLineCap(.round)
    ctx.move(to: pt(0.42, -0.70))
    ctx.addCurve(to: pt(0.92, -0.10), control1: pt(0.86, -0.78), control2: pt(0.94, -0.46))
    ctx.strokePath()

    // Sitting body: a bell that widens to the base.
    ctx.move(to: pt(-0.72, -0.92))
    ctx.addCurve(to: pt(-0.30, 0.16), control1: pt(-0.70, -0.30), control2: pt(-0.50, 0.02))
    ctx.addLine(to: pt(0.30, 0.16))
    ctx.addCurve(to: pt(0.72, -0.92), control1: pt(0.50, 0.02), control2: pt(0.70, -0.30))
    ctx.closePath()
    ctx.fillPath()

    // Head.
    let headY: CGFloat = 0.36, headR: CGFloat = 0.40
    ctx.fillEllipse(in: CGRect(x: c.x - headR * R, y: c.y + (headY - headR) * R, width: headR * 2 * R, height: headR * 2 * R))

    // Ears.
    for sign in [CGFloat(-1), 1] {
        ctx.move(to: pt(sign * 0.36, headY + 0.18))
        ctx.addLine(to: pt(sign * 0.46, headY + 0.68))
        ctx.addLine(to: pt(sign * 0.06, headY + 0.36))
        ctx.closePath()
        ctx.fillPath()
    }

    // Spindle hole, punched through the cat so it still reads as a record.
    ctx.restoreGState(); ctx.saveGState()
    ctx.setFillColor(orangeDeep)
    let hole = R * 0.10
    ctx.fillEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
    ctx.restoreGState()

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

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and build/AppIcon-1024.png" : "iconutil failed (\(p.terminationStatus))")
