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
        .background(ChoiceKeys())
    }
}

/// 1 / 2 / 3 pick a candidate while the HUD is listing them. The buttons only exist during an
/// ambiguity, so the number keys stay free for the rest of the app.
struct ChoiceKeys: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if case .ambiguous(let cands) = state.scan.phase {
                ForEach(Array(cands.indices.prefix(9)), id: \.self) { i in
                    Button("") { state.scan.choose(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                        .hidden()
                }
            }
        }
        .frame(width: 0, height: 0)
    }
}

struct PreviewPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Theme.panel
            let _ = state.noteCameraStatus()
            switch state.camera.status {
            case .running:
                CameraPreviewView(camera: state.camera)
            case .warmingUp(let name):
                ZStack {
                    CameraPreviewView(camera: state.camera)
                    Caption("WAKING \(name.uppercased())…")
                }
            case .dark:
                CameraMessage(title: "NO PICTURE FROM THE CAMERA", body: state.camera.darkStreamAdvice)
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
        let look = HUDLook(phase: previewPhase ?? scan.phase, recordNumber: scan.recordNumber, signal: scan.signal, noModelKey: !state.identifier.hasAnyKey, voiceProblem: state.voice.problem, manual: !state.autoCapture)
        ZStack {
            AlignmentGuide(color: look.color, progress: look.ring, videoAspect: state.camera.videoAspect)
            hudChrome(look)
        }
    }

    private func hudChrome(_ look: HUDLook) -> some View {
        let scan = state.scan
        return VStack {
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(Theme.display(30)).lineLimit(1).minimumScaleFactor(0.6)
                                    Text(c.detail).font(Theme.mono(14)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7)
                                }
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
        if case .dark(let name) = state.camera.status { return name.uppercased() + " · NO PICTURE" }
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

    init(phase: ScanPhase, recordNumber: Int, signal: CaptureSignal?, noModelKey: Bool? = nil, voiceProblem: String? = nil, manual: Bool = false) {
        // Coarse buckets: the exact numbers change every frame and made the hint line shimmer.
        let metrics = signal.map { String(format: "sharp %.0f · motion %.0f · scene %.0f",
                                          ($0.metrics.sharpness / 10).rounded() * 10,
                                          $0.metrics.motion.rounded(),
                                          ($0.metrics.sceneDelta / 5).rounded() * 5) } ?? "camera starting"
        switch phase {
        case .learning:
            state = "LEARNING"; meta = "keep the camera view empty for a second"
            headline = "HOLD ON…"; hint = "Learning what an empty scene looks like · " + metrics
        case .paused:
            state = "PAUSED"; headline = "AUTO MODE OFF"; hint = "Say “resume” or click AUTO MODE"
        case .armed(let reason):
            state = "ARMED"; meta = "record #\(recordNumber) · \(reason)"
            headline = manual ? "LINE IT UP · SAY “CAPTURE” OR PRESS SPACE" : "HOLD UP A RECORD"
            headlineSize = manual ? 48 : 64
            hint = (manual ? "Manual capture · the ring fills when the shot would be sharp · " : "Line it up in the guide and hold still for a second · say “capture” or press space to force · ") + metrics
            if let noKey = noModelKey, noKey { hint = "No vision-model key yet (Settings) — running on OCR + catalogue numbers only · " + metrics }
            if let vp = voiceProblem { hint = "Voice off — \(vp) · " + hint }
        case .steady(let p):
            color = Theme.green; state = manual ? "READY" : "STEADY"; meta = "record #\(recordNumber)"
            headline = manual ? (p >= 1 ? "SAY “CAPTURE” OR PRESS SPACE" : "HOLD IT…") : "HOLD IT…"; ring = p; ringLabel = manual ? "GO" : "HOLD"; hint = metrics
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
            color = Theme.orange; state = "\(cands.count) MATCHES"; meta = "press 1–\(cands.count) · or say the number, or NONE"
            headline = ""
            ring = 1; ringLabel = "\(cands.count)"; hint = "Scanning is paused until you answer · or flip it and press space — the B-side label usually settles it · say “review” to park it"
        case .needLabel(let guess):
            color = Theme.blue; state = "SHOW ME THE LABEL"; meta = "no confident match from the cover"
            headline = guess; headlineSize = 56; ring = signal?.steadyProgress ?? 0; ringLabel = "LABEL"
            hint = "Slide the record out and hold side A up to the camera · say “skip” to park it for review"
        case .retry(let guess, let detail):
            color = Theme.amber; state = "TRY AGAIN"; meta = "nothing saved yet · one more look"
            headline = guess; headlineSize = 56; ring = signal?.steadyProgress ?? 0; ringLabel = "RETRY"
            hint = "\(detail) · hold it steadier and closer, or turn it to a clearer side · say “skip” or “review” to park it"
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
        // The engine already smooths its own numbers; this just stops the last few pixels of the
        // ring from stepping, so filling and dipping read as one movement.
        .animation(.easeOut(duration: 0.3), value: progress)
        .animation(.easeOut(duration: 0.25), value: color)
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

/// Corner brackets around the analysed region plus a faint disc outline: "put the record here".
struct AlignmentGuide: View {
    let color: Color
    let progress: Double
    /// Set when the picture is letterboxed (a portrait phone in a landscape panel) so the guide
    /// stays over the video instead of over the black bars. nil when the video fills the panel.
    var videoAspect: CGFloat?
    var body: some View {
        GeometryReader { geo in
            let video = Self.videoRect(in: geo.size, aspect: videoAspect)
            let w = video.width, h = video.height
            let rect = CGRect(x: video.minX + w * 0.18, y: video.minY + h * 0.08, width: w * 0.64, height: h * 0.62)
            let side = min(rect.width, rect.height)
            let disc = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            ZStack {
                Path { p in
                    let l: CGFloat = 36
                    for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
                        p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * l, y: y))
                    }
                }
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .square))
                Circle().stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [10, 8])).frame(width: disc.width, height: disc.height).position(x: disc.midX, y: disc.midY)
                Circle().stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 6])).frame(width: disc.width * 0.36, height: disc.height * 0.36).position(x: disc.midX, y: disc.midY)
                if progress > 0 {
                    Rectangle().fill(color.opacity(0.08)).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                }
                Text("LINE UP THE SLEEVE OR LABEL HERE").font(Theme.mono(11)).tracking(2).foregroundStyle(color.opacity(0.8))
                    .position(x: rect.midX, y: rect.minY - 14)
            }
            .animation(.easeOut(duration: 0.25), value: color)
            .animation(.easeOut(duration: 0.3), value: progress)
        }
        .allowsHitTesting(false)
    }

    /// The part of the panel the picture actually covers.
    static func videoRect(in size: CGSize, aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if aspect > size.width / size.height {
            let vh = size.width / aspect
            return CGRect(x: 0, y: (size.height - vh) / 2, width: size.width, height: vh)
        }
        let vw = size.height * aspect
        return CGRect(x: (size.width - vw) / 2, y: 0, width: vw, height: size.height)
    }
}
