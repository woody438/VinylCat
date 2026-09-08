import SwiftUI

/// The three capture numbers as colour gauges — SHARP, STILL, RECORD (how much of one is in front of
/// the camera) — red / amber / green against the thresholds the engine actually fires on, so the
/// operator sees *why* the ring isn't filling without reading "sharp 350 · motion 0 · scene 115".
struct SignalGauges: View {
    let metrics: FrameMetrics?
    var tuning: CaptureTuning = .fromDefaults()
    /// Settings shows the raw number under each bar; the HUD keeps them to bars and labels.
    var showNumbers = false

    struct Gauge: Identifiable {
        let id: String
        let fill: Double
        let color: Color
        let number: String
        let help: String
    }

    var gauges: [Gauge] {
        guard let m = metrics else {
            return ["SHARP", "STILL", "RECORD"].map { Gauge(id: $0, fill: 0, color: Theme.muted, number: "—", help: "camera starting") }
        }
        let t = tuning
        let sharp = Self.tone(m.sharpness, good: t.sharpnessMin, ok: t.sharpnessMin * 0.6)
        let still = Self.tone(-m.motion, good: -t.motionMax, ok: -t.motionMax * 2)          // lower is better
        let record = Self.tone(m.sceneDelta, good: t.sceneDeltaMin, ok: t.sceneDeltaMin * 0.6)
        return [
            Gauge(id: "SHARP", fill: min(1, m.sharpness / (t.sharpnessMin * 2)), color: sharp, number: String(format: "%.0f", m.sharpness),
                  help: "Focus. Green from \(Int(t.sharpnessMin)) — the \"sharpness needed\" slider in Settings."),
            Gauge(id: "STILL", fill: 1 - min(1, m.motion / (t.motionMax * 3)), color: still, number: String(format: "%.1f", m.motion),
                  help: "Movement between frames. Green under \(Int(t.motionMax)) — hold it, or rest it on the table."),
            Gauge(id: "RECORD", fill: min(1, m.sceneDelta / (t.sceneDeltaMin * 3)), color: record, number: String(format: "%.0f", m.sceneDelta),
                  help: "How different the picture is from the empty scene. Green from \(Int(t.sceneDeltaMin)) — the \"scene change needed\" slider."),
        ]
    }

    /// Green at or past `good`, amber at or past `ok`, red below.
    static func tone(_ v: Double, good: Double, ok: Double) -> Color {
        v >= good ? Theme.green : v >= ok ? Theme.amber : Theme.red
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(gauges) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(g.id).font(Theme.mono(10)).tracking(1.5).foregroundStyle(Theme.muted)
                        if showNumbers { Text(g.number).font(Theme.mono(10)).foregroundStyle(g.color) }
                    }
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.raised).frame(width: 64, height: 5)
                        Rectangle().fill(g.color).frame(width: max(2, 64 * g.fill), height: 5)
                    }
                }
                .help(g.help)
            }
        }
        .animation(.easeOut(duration: 0.2), value: gauges.map(\.fill))
    }
}

extension CaptureTuning {
    /// The Settings sliders (UserDefaults) over the built-in defaults.
    static func fromDefaults() -> CaptureTuning {
        var t = CaptureTuning()
        let d = UserDefaults.standard
        if let v = d.object(forKey: "sharpnessMin") as? Double { t.sharpnessMin = v }
        if let v = d.object(forKey: "steadySeconds") as? Double { t.steadySeconds = v }
        if let v = d.object(forKey: "sceneDeltaMin") as? Double { t.sceneDeltaMin = v }
        return t
    }
}
