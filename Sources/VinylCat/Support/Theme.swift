import SwiftUI

/// Direction A — dark control-room. Values mirror design/mockups/build.mjs.
enum Theme {
    static let bg = Color(hex: 0x0E1012)
    static let panel = Color(hex: 0x15181B)
    static let line = Color(hex: 0x23272B)
    static let raised = Color(hex: 0x2A2F34)
    static let muted = Color(hex: 0x8A9096)
    static let text = Color(hex: 0xF2EFE8)
    static let secondary = Color(hex: 0xC9C5BB)
    static let green = Color(hex: 0x7EE2A8)
    static let amber = Color(hex: 0xF0B26B)
    static let blue = Color(hex: 0x7CC4F5)
    static let orange = Color(hex: 0xF28B5C)
    static let red = Color(hex: 0xF06C6C)
    static let greenBg = Color(hex: 0x12211A)
    static let amberBg = Color(hex: 0x251D12)
    static let blueBg = Color(hex: 0x122029)
    static let orangeBg = Color(hex: 0x2A1A12)
    static let redBg = Color(hex: 0x2A1414)

    /// Condensed display face (stands in for Barlow Condensed).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    /// Mono data face (stands in for IBM Plex Mono).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Small-caps tracking label used throughout the chrome.
struct Caption: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(Theme.mono(11)).tracking(1.5).foregroundStyle(color)
    }
}
