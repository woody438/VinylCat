import SwiftUI

/// The VinylCat mark: a record that is also a cat's head — the disc is the face, two ears stand
/// above its edge, grooves run round a burnt-orange label. Drawn, not an asset, so it is crisp at
/// any size; `scripts/make-icon.swift` draws the same geometry for the .icns.
///
/// Geometry lives in `LogoGeometry` (unit square, y down) so both renderers agree.
struct LogoMark: View {
    var label: Color = LogoGeometry.burntOrange
    /// The head/disc colour. Near-black on the icon's plate; on the app's dark bar a lighter grey,
    /// or the silhouette — ears included — vanishes and only the label shows.
    var head: Color = LogoGeometry.disc
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let g = LogoGeometry(size: s)
            ZStack {
                // Ears first, so the disc's edge sits over their base.
                Path { p in g.ear(&p, left: true); g.ear(&p, left: false) }.fill(head)
                Circle().fill(head).frame(width: g.r * 2, height: g.r * 2).position(g.c)
                ForEach(0..<5, id: \.self) { i in
                    let rr = g.r * (0.52 + CGFloat(i) * 0.09)
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: max(0.5, s * 0.012))
                        .frame(width: rr * 2, height: rr * 2).position(g.c)
                }
                Circle().fill(label).frame(width: g.labelR * 2, height: g.labelR * 2).position(g.c)
                Circle().stroke(LogoGeometry.burntOrangeDeep, lineWidth: max(0.5, s * 0.018)).frame(width: g.labelR * 2, height: g.labelR * 2).position(g.c)
                Circle().fill(head).frame(width: g.holeR * 2, height: g.holeR * 2).position(g.c)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("VinylCat")
    }
}

/// Shared proportions. Everything is a fraction of the square's side; the disc sits low so the
/// ears have room above it.
struct LogoGeometry {
    static let disc = Color(hex: 0x0A0B0C)
    static let burntOrange = Color(hex: 0xCC6A3C)
    static let burntOrangeDeep = Color(hex: 0x9E4F2A)

    let size: CGFloat
    init(size: CGFloat) { self.size = size }

    var c: CGPoint { CGPoint(x: size * 0.5, y: size * 0.56) }
    var r: CGFloat { size * 0.40 }
    var labelR: CGFloat { r * 0.36 }
    var holeR: CGFloat { r * 0.05 }

    /// A triangular ear with a softened tip: base on the disc's edge, tip well outside it. Angles
    /// in degrees, measured anticlockwise from 3 o'clock with y down (so 90° is straight up).
    func ear(_ p: inout Path, left: Bool) {
        let a0: CGFloat = left ? 113 : 67        // inner base point
        let a1: CGFloat = left ? 151 : 29        // outer base point
        let tipAngle: CGFloat = left ? 128 : 52  // a touch inward of the base's middle, so the ears stand up rather than flare
        let base0 = point(angle: a0, radius: r * 0.98)
        let base1 = point(angle: a1, radius: r * 0.98)
        let tip = point(angle: tipAngle, radius: r * 1.58)
        // Two points either side of the tip, along the ear's edges, give the rounded point.
        let soften: CGFloat = 0.14
        let t0 = CGPoint(x: tip.x + (base0.x - tip.x) * soften, y: tip.y + (base0.y - tip.y) * soften)
        let t1 = CGPoint(x: tip.x + (base1.x - tip.x) * soften, y: tip.y + (base1.y - tip.y) * soften)
        p.move(to: base0)
        p.addLine(to: t0)
        p.addQuadCurve(to: t1, control: tip)
        p.addLine(to: base1)
        p.closeSubpath()
    }

    func point(angle deg: CGFloat, radius: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + radius * cos(a), y: c.y - radius * sin(a))
    }
}
