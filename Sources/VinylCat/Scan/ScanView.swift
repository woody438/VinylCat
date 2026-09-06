import SwiftUI

struct ScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewPane()
                Rectangle().fill(Theme.line).frame(width: 1)
                RightRail().frame(width: 340)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            BottomBar()
        }
    }
}

struct PreviewPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Theme.panel
            switch state.camera.status {
            case .running:
                CameraPreviewView(box: state.camera.box)
            case .idle:
                Caption("STARTING CAMERA…")
            case .unauthorized:
                CameraMessage(title: "CAMERA ACCESS NEEDED",
                              body: "Allow VinylCat in System Settings → Privacy & Security → Camera, then relaunch.")
            case .noCamera:
                CameraMessage(title: "NO CAMERA FOUND", body: "Connect a camera or bring an iPhone nearby for Continuity Camera.")
            case .failed(let msg):
                CameraMessage(title: "CAMERA FAILED", body: msg)
            }
            HUDOverlay()
        }
        .clipped()
    }
}

struct CameraMessage: View {
    let title: String
    let body_: String
    init(title: String, body: String) { self.title = title; self.body_ = body }
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(Theme.display(40)).foregroundStyle(Theme.red)
            Text(body_).font(Theme.mono(13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
    }
}

/// HUD bound to the scan controller's phase. Colours/copy mirror the mockups.
struct HUDOverlay: View {
    @Environment(AppState.self) private var state
    @Environment(\.previewPhase) private var previewPhase

    var body: some View {
        let scan = state.scan
        let look = HUDLook(phase: previewPhase ?? scan.phase, recordNumber: scan.recordNumber, signal: scan.signal, noModelKey: !state.identifier.hasAnyKey, voiceProblem: state.voice.problem)
        VStack {
            HStack(alignment: .top) {
                Caption(cameraTag)
                Spacer()
                StabilityRing(progress: look.ring, color: look.color, label: look.ringLabel)
            }
            .padding(20)
            Spacer()
            StateBanner(color: look.color, state: look.state, meta: look.meta) {
                if case .ambiguous(let cands) = previewPhase ?? scan.phase {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(cands.enumerated()), id: \.offset) { i, c in
                            HStack(alignment: .firstTextBaseline, spacing: 18) {
                                Text("\(i + 1)").font(Theme.display(44)).foregroundStyle(Theme.orange).frame(width: 40, alignment: .leading)
                                Text(c).font(Theme.display(30)).lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                    }
                } else {
                    Text(look.headline).font(Theme.display(look.headlineSize)).lineLimit(1).minimumScaleFactor(0.5)
                }
                if !look.subline.isEmpty {
                    Text(look.subline).font(Theme.display(30, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Text(look.hint).font(Theme.mono(13)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private var cameraTag: String {
        if case .running(let name) = state.camera.status { return name.uppercased() + " · LIVE" }
        return "CAMERA"
    }
}

/// Pure mapping from phase → colours and copy, so the HUD and tests share one source of truth.
struct HUDLook {
    var color: Color = Theme.muted
    var state = "ARMED"
    var meta = ""
    var headline = ""
    var headlineSize: CGFloat = 64
    var subline = ""
    var hint = ""
    var ring: Double = 0
    var ringLabel = "READY"

    init(phase: ScanPhase, recordNumber: Int, signal: CaptureSignal?, noModelKey: Bool? = nil, voiceProblem: String? = nil) {
        let metrics = signal.map { String(format: "sharp %.0f · motion %.1f · scene %.0f", $0.metrics.sharpness, $0.metrics.motion, $0.metrics.sceneDelta) } ?? "camera starting"
        switch phase {
        case .learning:
            state = "LEARNING"; meta = "keep the camera view empty for a second"
            headline = "HOLD ON…"; hint = "Learning what an empty scene looks like · " + metrics
        case .paused:
            state = "PAUSED"; headline = "AUTO MODE OFF"; hint = "Say “resume” or click AUTO MODE"
        case .armed(let reason):
            state = "ARMED"; meta = "record #\(recordNumber) · \(reason)"
            headline = "HOLD UP A RECORD"
            hint = "Auto-captures when the image is steady and sharp · say “capture” to force · " + metrics
            if let noKey = noModelKey, noKey { hint = "No vision-model key yet (Settings) — running on OCR + catalogue numbers only · " + metrics }
            if let vp = voiceProblem { hint = "Voice off — \(vp) · " + hint }
        case .steady(let p):
            color = Theme.green; state = "STEADY"; meta = "record #\(recordNumber)"
            headline = "HOLD IT…"; ring = p; ringLabel = "HOLD"; hint = metrics
        case .captured:
            color = Theme.green; state = "CAPTURED"; meta = "photo saved"
            headline = "GOT IT"; ring = 1; ringLabel = "SHOT"; hint = "Lift the record away to arm the next shot"
        case .reading(let step):
            color = Theme.amber; state = "READING"; meta = step
            headline = "READING THE LABEL…"; ring = 1; ringLabel = "SHOT"; hint = "Local OCR → vision model → Discogs"
        case .searching:
            color = Theme.blue; state = "SEARCHING"; meta = "Discogs"
            headline = "LOOKING IT UP…"; ring = 1; ringLabel = "SHOT"; hint = ""
        case .matched(let title, let detail, let m):
            color = Theme.green; state = "MATCHED"; meta = m
            headline = title; subline = detail; ring = 1; ringLabel = "OK"; hint = ""
        case .ambiguous(let cands):
            color = Theme.orange; state = "\(cands.count) MATCHES"; meta = "say ONE, TWO, THREE or NONE"
            headline = ""
            ring = 1; ringLabel = "\(cands.count)"; hint = "Or flip it — the B-side label usually settles it · say “review” to park it"
        case .needLabel(let guess):
            color = Theme.blue; state = "SHOW ME THE LABEL"; meta = "no confident match from the cover"
            headline = guess; headlineSize = 56; ring = signal?.steadyProgress ?? 0; ringLabel = "LABEL"
            hint = "Slide the record out and hold side A up to the camera · say “skip” to park it for review"
        case .awaitingShot(let kind, let i, let n, let header):
            color = Theme.blue; state = "NEXT SHOT · \(i) OF \(n)"; meta = header
            headline = kind.uppercased(); ring = signal?.steadyProgress ?? 0; ringLabel = "HOLD"
            hint = "say “skip” to move on · “done” to finish this record · “undo” to retake the last shot"
        case .notFound(let guess, let detail):
            color = Theme.red; state = "NOT FOUND"; meta = "added to review queue · photo kept"
            headline = guess; headlineSize = 56; ring = 1; ringLabel = "—"; hint = detail
        case .duplicate(let title):
            color = Theme.amber; state = "ALREADY CATALOGUED"; meta = "skipped"
            headline = title; headlineSize = 56; ring = 1; ringLabel = "DUP"; hint = "Say “add anyway” to keep a second copy"
        }
    }
}

struct StabilityRing: View {
    let progress: Double
    let color: Color
    let label: String
    var body: some View {
        ZStack {
            Circle().stroke(Theme.raised, lineWidth: 7)
            Circle().trim(from: 0, to: progress).stroke(color, style: .init(lineWidth: 7, lineCap: .butt)).rotationEffect(.degrees(-90))
            Text(label).font(Theme.mono(11)).tracking(1).foregroundStyle(color)
        }
        .frame(width: 84, height: 84)
    }
}

struct StateBanner<Content: View>: View {
    let color: Color
    let state: String
    let meta: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(state).font(Theme.display(22)).tracking(3).foregroundStyle(color)
                Text(meta).font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.vertical, 20)
        .background(Theme.bg.opacity(0.94))
        .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 4) }
    }
}

struct RightRail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let scan = state.scan
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Caption("NEXT")
                Text(scan.items.isEmpty ? "WAITING" : "RECORD #\(scan.recordNumber)").font(Theme.display(40)).lineLimit(1).minimumScaleFactor(0.6)
                Text("Show the cover first. If there is no picture sleeve, hold the label close to the camera.")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 22)
            .background(Theme.panel)
            Rectangle().fill(Theme.line).frame(height: 1)

            Caption("THIS SESSION").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            if scan.items.isEmpty {
                Text("Nothing scanned yet.").font(Theme.mono(13)).foregroundStyle(Theme.muted).padding(.horizontal, 20)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scan.items.prefix(8)) { item in SessionRow(item: item) }
                }
                .padding(.horizontal, 20)
            }
            Spacer()
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Meter(title: "DISCOGS", value: "0/60", color: Theme.text)
                Meter(title: "LLM COST", value: "$0.00", color: Theme.text)
                Meter(title: "REVIEW", value: "\(state.reviewCount)", color: Theme.red)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }
}

struct SessionRow: View {
    let item: SessionItem
    var body: some View {
        let color: Color = switch item.tone { case .normal: Theme.text; case .review: Theme.red; case .incomplete: Theme.amber }
        HStack(spacing: 12) {
            Group {
                if let cg = item.thumbnail {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.raised
                }
            }
            .frame(width: 52, height: 52).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.mono(13)).foregroundStyle(color).lineLimit(1)
                Text(item.meta).font(Theme.mono(11)).foregroundStyle(item.tone == .normal ? Theme.muted : color).lineLimit(1)
            }
        }
    }
}

struct Meter: View {
    let title: String, value: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(title)
            Text(value).font(Theme.mono(16)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BottomBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var camera = state.camera
        HStack(spacing: 28) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill").font(.system(size: 12))
                Picker("", selection: $camera.selectedDeviceID) {
                    ForEach(camera.devices, id: \.uniqueID) { d in
                        Text(d.localizedName.uppercased()).tag(Optional(d.uniqueID))
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Text("VOICE · “capture” · “flip” · “skip” · “review” · “forty-fives” · “albums” · “undo”")
            Spacer()
            Text("SESSION · \(state.scan.items.count) SHOTS")
        }
        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 24)
        .frame(height: 44)
    }
}
