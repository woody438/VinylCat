import SwiftUI

/// The VinylCat mark: a plain black record with a burnt-orange label, and two fine whiskers
/// reaching out from either side of the label — the cat is implied, nothing more. Drawn, not an
/// asset, so it is crisp at any size; `scripts/make-icon.swift` draws the same geometry for the
/// .icns. Proportions live in `LogoGeometry` (unit square, y down) so both renderers agree.
struct LogoMark: View {
    var label: Color = LogoGeometry.burntOrange
    /// The disc colour. Near-black on the icon's plate; on the app's dark bar a lighter grey so the
    /// disc still reads as a shape.
    var disc: Color = LogoGeometry.disc
    var whisker: Color = LogoGeometry.cream
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let g = LogoGeometry(size: s)
            ZStack {
                Circle().fill(disc).frame(width: g.r * 2, height: g.r * 2).position(g.c)
                // Grooves: barely there. The old high-contrast rings made it look like clip art.
                ForEach(0..<3, id: \.self) { i in
                    let rr = g.r * (0.60 + CGFloat(i) * 0.12)
                    Circle().stroke(Color.white.opacity(0.05), lineWidth: max(0.5, s * 0.006))
                        .frame(width: rr * 2, height: rr * 2).position(g.c)
                }
                Circle().fill(label).frame(width: g.labelR * 2, height: g.labelR * 2).position(g.c)
                Circle().stroke(LogoGeometry.burntOrangeDeep, lineWidth: max(0.5, s * 0.008)).frame(width: g.labelR * 2, height: g.labelR * 2).position(g.c)
                Circle().fill(disc).frame(width: g.holeR * 2, height: g.holeR * 2).position(g.c)
                Path { p in g.whiskers(&p) }
                    .stroke(whisker, style: StrokeStyle(lineWidth: max(0.6, s * g.whiskerWidth), lineCap: .round))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("VinylCat")
    }
}

/// Shared proportions. Everything is a fraction of the square's side.
struct LogoGeometry {
    static let disc = Color(hex: 0x0E1012)
    static let burntOrange = Color(hex: 0xCC6A3C)
    static let burntOrangeDeep = Color(hex: 0x9E4F2A)
    static let cream = Color(hex: 0xF2EFE8)

    let size: CGFloat
    init(size: CGFloat) { self.size = size }

    var c: CGPoint { CGPoint(x: size * 0.5, y: size * 0.5) }
    var r: CGFloat { size * 0.46 }
    var labelR: CGFloat { r * 0.30 }
    var holeR: CGFloat { r * 0.035 }
    /// Line width as a fraction of the side — thin.
    var whiskerWidth: CGFloat { 0.0075 }

    /// Two whiskers a side, from just outside the label to near the disc's edge, splayed a few
    /// degrees and bowed very slightly outward — the way real whiskers hang.
    func whiskers(_ p: inout Path) {
        for side in [CGFloat(-1), 1] {
            for (lift, angle) in [(CGFloat(0.13), CGFloat(7)), (CGFloat(-0.13), CGFloat(-7))] {
                let x0 = c.x + side * (labelR + r * 0.10)
                let y0 = c.y - lift * labelR
                let len = r * 0.55
                let a = angle * .pi / 180
                let x1 = x0 + side * len * cos(a)
                let y1 = y0 - len * sin(a)
                // Control point a touch further from the centre line than the straight chord, for the bow.
                let cx = (x0 + x1) / 2
                let cy = (y0 + y1) / 2 - (lift > 0 ? 1 : -1) * r * 0.035
                p.move(to: CGPoint(x: x0, y: y0))
                p.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy))
            }
        }
    }
}
