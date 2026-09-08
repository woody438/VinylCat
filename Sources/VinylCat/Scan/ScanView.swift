import SwiftUI

struct ScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewPane().tourAnchor(.preview)
                Rectangle().fill(Theme.line).frame(width: 1)
                RightRail().frame(width: 340).tourAnchor(.rail)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            BottomBar().tourAnchor(.bottomBar)
        }
        .background(ScanKeys())
    }
}

/// A keyboard action on the Scan tab. Keys and voice fire the same commands, so the legend along
/// the bottom can show both: the key, and — while voice is on — the word.
struct ScanKey: Identifiable, Equatable {
    let key: KeyEquivalent
    /// What the legend prints on the key cap.
    let label: String
    let action: String
    /// The spoken phrase that does the same thing.
    let word: String
    let command: VoiceCommand
    var id: String { label + action }
    static func == (a: ScanKey, b: ScanKey) -> Bool { a.id == b.id }

    static let capture = ScanKey(key: .space, label: "SPACE", action: "capture", word: "capture", command: .capture)
    static let skip = ScanKey(key: "s", label: "S", action: "skip · to the review queue", word: "skip", command: .skip)
    static let skipShot = ScanKey(key: "s", label: "S", action: "skip this shot", word: "skip", command: .skip)
    static let done = ScanKey(key: "d", label: "D", action: "done", word: "done", command: .done)
    static let undo = ScanKey(key: "u", label: "U", action: "undo · last photo, then the scan", word: "undo", command: .undo)
    static let retake = ScanKey(key: "u", label: "U", action: "retake the last shot", word: "undo", command: .undo)
    static let wrong = ScanKey(key: "w", label: "W", action: "wrong record", word: "wrong record", command: .wrong)
    static let flip = ScanKey(key: "f", label: "F", action: "flip · B-side", word: "flip", command: .flip)
    static let review = ScanKey(key: "r", label: "R", action: "park for review", word: "review", command: .review)
    static let again = ScanKey(key: .escape, label: "ESC", action: "start over", word: "again", command: .again)
    static let none = ScanKey(key: "n", label: "N", action: "none of those", word: "none", command: .none)
    static let addAnyway = ScanKey(key: .return, label: "RETURN", action: "add anyway · second copy", word: "add anyway", command: .addAnyway)
    static let addPhoto = ScanKey(key: "p", label: "P", action: "add a photo to the last record", word: "add photo", command: .addPhoto)
    /// Legend-only stand-in for the number keys, which `ScanKeys` installs one by one.
    static let pick = ScanKey(key: "1", label: "1–9", action: "pick a match", word: "one, two…", command: .one)

    /// What is worth doing from the keyboard in each phase — the legend shows exactly this list.
    static func set(for phase: ScanPhase) -> [ScanKey] {
        switch phase {
        case .ambiguous: [pick, none, flip, review]
        case .needLabel, .retry: [capture, skip, again]
        case .awaitingShot: [capture, skipShot, done, retake]
        case .duplicate: [addAnyway, again]
        case .paused: []
        default: [capture, flip, undo, wrong, addPhoto]
        }
    }
}

/// Installs the phase's keys as hidden buttons. Bare letters are safe here because the Scan tab has
/// no text field; the buttons go away with the tab.
struct ScanKeys: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let phase = state.scan.phase
        Group {
            ForEach(ScanKey.set(for: phase).filter { $0 != .pick }) { k in
                Button("") { state.scan.handle(command: k.command) }.keyboardShortcut(k.key, modifiers: []).hidden()
            }
            if case .ambiguous(let cands) = phase {
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
        let look = HUDLook(phase: previewPhase ?? scan.phase, recordNumber: scan.recordNumber, signal: scan.signal, noModelKey: !state.identifier.hasAnyKey, voiceProblem: state.voice.problem, manual: !state.autoCapture, voiceOff: state.voice.status != .listening)
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
                    // Up to nine variants. Three fit at full size; more than that get a tighter row
                    // and a scrolling list capped at about four rows, so the banner never eats the preview.
                    let compact = cands.count > 3
                    let rows = VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                        ForEach(Array(cands.enumerated()), id: \.offset) { i, c in
                            HStack(alignment: .firstTextBaseline, spacing: 18) {
                                Text("\(i + 1)").font(Theme.display(compact ? 30 : 44)).foregroundStyle(Theme.orange).frame(width: 40, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(Theme.display(compact ? 22 : 30)).lineLimit(1).minimumScaleFactor(0.6)
                                    Text(c.detail).font(Theme.mono(compact ? 12 : 14)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }
                        }
                    }
                    if compact { ScrollView(.vertical) { rows }.frame(maxHeight: 200) } else { rows }
                } else {
                    Text(look.headline).font(Theme.display(look.headlineSize)).lineLimit(1).minimumScaleFactor(0.5)
                }
                if !look.subline.isEmpty {
                    Text(look.subline).font(Theme.display(30, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Text(look.hint).font(Theme.mono(13)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .tourAnchor(.banner)
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

    init(phase: ScanPhase, recordNumber: Int, signal: CaptureSignal?, noModelKey: Bool? = nil, voiceProblem: String? = nil, manual: Bool = false, voiceOff: Bool = false) {
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
            else if voiceOff { hint = "Voice off — click VOICE in the top bar to use spoken commands · " + hint }
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
            color = Theme.orange; state = "\(cands.count) MATCHES"; meta = "press 1–\(cands.count) · N for none · or say the number" + (cands.count > 4 ? " · scroll for the rest" : "")
            headline = ""
            ring = 1; ringLabel = "\(cands.count)"; hint = "Scanning is paused until you answer · F then SPACE shoots the B-side, which usually settles it · R parks it for review"
        case .needLabel(let guess):
            color = Theme.blue; state = "SHOW ME THE LABEL"; meta = "no confident match from the cover"
            headline = guess; headlineSize = 56; ring = signal?.steadyProgress ?? 0; ringLabel = "LABEL"
            hint = "Slide the record out and hold side A up to the camera · S parks it in the review queue"
        case .retry(let guess, let detail):
            color = Theme.amber; state = "TRY AGAIN"; meta = "nothing saved yet · one more look"
            headline = guess; headlineSize = 56; ring = signal?.steadyProgress ?? 0; ringLabel = "RETRY"
            hint = "\(detail) · hold it steadier and closer, or turn it to a clearer side · S parks it in the review queue"
        case .awaitingShot(let kind, let i, let n, let header):
            color = Theme.blue; state = "NEXT SHOT · \(i) OF \(n)"; meta = header
            headline = kind.uppercased(); ring = signal?.steadyProgress ?? 0; ringLabel = "HOLD"
            hint = "S skips this shot · D finishes the record · U retakes the last shot"
        case .notFound(let guess, let detail):
            color = Theme.red; state = "NOT FOUND"; meta = "added to review queue · photo kept"
            headline = guess; headlineSize = 56; ring = 1; ringLabel = "—"; hint = detail
        case .duplicate(let title):
            color = Theme.amber; state = "ALREADY CATALOGUED"; meta = "skipped"
            headline = title; headlineSize = 56; ring = 1; ringLabel = "DUP"; hint = "RETURN keeps a second copy · or just show the next record"
        case .error(let title, let detail):
            color = Theme.red; state = "ERROR"; meta = "nothing matched · photo parked in the review queue"
            headline = title; headlineSize = 56; ring = 1; ringLabel = "!"; hint = detail
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
    @State private var pendingDelete: SessionItem?

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
                    ForEach(scan.items.prefix(8)) { item in SessionRow(item: item) { pendingDelete = item } }
                }
                .padding(.horizontal, 20)
            }
            Spacer()
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Meter(title: "DISCOGS", value: "\(state.discogs.used)/\(state.discogs.limit)", color: state.discogs.remaining < 10 ? Theme.amber : Theme.text)
                    .help("Discogs calls used in the current minute (from Discogs' own rate-limit headers)")
                Meter(title: "LLM COST", value: String(format: "$%.3f", state.identifier.sessionCostUSD), color: Theme.text)
                    .help("Vision-model spend this session · \(state.identifier.reads) reads")
                Meter(title: "REVIEW", value: "\(state.reviewCount)", color: Theme.red)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete Record", role: .destructive) {
                if let id = item.recordID { Task { await state.scan.delete(id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removes it from the Library with its photos, and from your Discogs collection. This can't be undone.")
        }
    }
}

struct SessionRow: View {
    @Environment(AppState.self) private var state
    let item: SessionItem
    var onDelete: () -> Void = {}
    @State private var hovering = false
    var body: some View {
        let color: Color = switch item.tone { case .normal: Theme.text; case .review: Theme.red; case .rejected: Theme.red }
        HStack(spacing: 10) {
            if item.recordID != nil {
                // Bin on the left, as asked: one click to take a mis-scan out of the Library and Discogs.
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12))
                        .foregroundStyle(hovering ? Theme.red : Theme.muted.opacity(0.45))
                        .frame(width: 20, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this record — from the Library and from your Discogs collection")
            }
            Group {
                if let cg = item.thumbnail {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.raised
                }
            }
            .frame(width: 52, height: 52).clipped().opacity(item.tone == .rejected ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.mono(13)).foregroundStyle(color).lineLimit(1).strikethrough(item.tone == .rejected, color: Theme.red)
                Text(item.meta).font(Theme.mono(11)).foregroundStyle(item.tone == .normal ? Theme.muted : color).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let id = item.recordID {
                // Thumbs: the chosen one stays lit; the other shows on hover.
                HStack(spacing: 4) {
                    thumb("hand.thumbsup", lit: item.verdict == .up, color: Theme.green, help: "Correct match") { state.scan.verdict(id, .up) }
                    thumb("hand.thumbsdown", lit: item.verdict == .down, color: Theme.red, help: "Wrong record — keep out of Discogs, log for tuning") { state.scan.verdict(id, .down) }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func thumb(_ symbol: String, lit: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: lit ? symbol + ".fill" : symbol)
                .font(.system(size: 13))
                .foregroundStyle(lit ? color : Theme.muted.opacity(hovering ? 0.9 : 0.35))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
    @Environment(\.previewPhase) private var previewPhase

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
            let listening = state.voice.status == .listening
            let keys = ScanKey.set(for: previewPhase ?? state.scan.phase)
            // The legend follows the phase: what the keys do right now, and the word that does the same when voice is on.
            HStack(spacing: 18) {
                ForEach(keys) { KeyChip(key: $0, voice: listening) }
            }
            .animation(.easeOut(duration: 0.15), value: keys)
            Spacer()
            Text(listening ? "VOICE ON" : "VOICE OFF").lineLimit(1).fixedSize()
                .foregroundStyle(listening ? Theme.green : Theme.muted)
                .help(listening ? "Listening — the green words are what to say. Also: “forty-fives”, “albums”, “pause”, “manual mode”."
                                : "Click VOICE in the top bar to say the green words instead of pressing keys")
            Text("SESSION · \(state.scan.items.count) SHOTS")
        }
        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 24)
        .frame(height: 44)
    }
}

/// One legend entry: the key cap, what it does, and the spoken word when voice is listening.
struct KeyChip: View {
    let key: ScanKey
    let voice: Bool
    var body: some View {
        HStack(spacing: 7) {
            Text(key.label).font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.text)
                .padding(.horizontal, 6).frame(height: 20)
                .background(Theme.raised).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            Text(key.action).font(Theme.mono(12)).foregroundStyle(Theme.secondary).lineLimit(1)
            if voice { Text("“\(key.word)”").font(Theme.mono(11)).foregroundStyle(Theme.green.opacity(0.85)).lineLimit(1) }
        }
        .fixedSize()
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
                // Everything outside the analysed region goes dim: the record reads as lined up when
                // it is the bright part of the picture. Even-odd fill leaves the guide itself clear.
                Path { p in p.addRect(video); p.addRect(rect) }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Path { p in p.addRect(video); p.addRect(rect) }
                    .fill(color.opacity(0.10), style: FillStyle(eoFill: true))
                Rectangle().stroke(color.opacity(0.25), lineWidth: 1).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
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
