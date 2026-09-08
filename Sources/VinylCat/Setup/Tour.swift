import SwiftUI

/// First-run callout tour. Runs once after the setup wizard (or from Settings → SHOW TOUR AGAIN):
/// dims the window, cuts a hole around one control at a time and explains it in a bubble.
/// Views tag the things worth pointing at with `.tourAnchor(_:)`; `TourHost` reads those bounds
/// back through a preference and lays the overlay on top of the main view.

/// Which on-screen element a callout points at.
enum TourAnchor: String, CaseIterable, Hashable {
    case tabs, preview, banner, format, capture, voice, rail, bottomBar
    case library, review
    case settingsIdentification, settingsDiscogs, settingsVoice, settingsCapture, settingsTests
}

struct TourStep: Identifiable, Equatable {
    /// Where the bubble sits relative to the anchor. `.inside` centres it over a large region (no arrow).
    enum Placement { case below, above, leading, trailing, inside }
    let anchor: TourAnchor
    let tab: AppTab
    let placement: Placement
    let title: String
    let body: String
    var id: TourAnchor { anchor }

    static let all: [TourStep] = [
        TourStep(anchor: .tabs, tab: .scan, placement: .below, title: "FOUR PLACES TO BE",
                 body: "SCAN is where records get catalogued. LIBRARY is everything saved so far. REVIEW holds anything it could not identify. SETTINGS is keys, cameras and tuning. This tour visits all four — NEXT or → to move on, ESC to leave it."),
        TourStep(anchor: .preview, tab: .scan, placement: .inside, title: "THE CAMERA",
                 body: "Hold a sleeve or label inside the brackets, about 40 cm from the camera, and keep still. The ring in the top-right corner fills as the shot gets steady and sharp; a chime means it has been captured. Lift the record away to arm the next one."),
        TourStep(anchor: .banner, tab: .scan, placement: .above, title: "THE STATUS BANNER",
                 body: "The colour is the state: grey armed, green captured or matched, amber reading, blue searching Discogs, orange when it needs you to pick between matches, red not found. The small line underneath always says what to do or say next."),
        TourStep(anchor: .format, tab: .scan, placement: .below, title: "TELL IT WHAT YOU'RE HOLDING",
                 body: "7\" singles, 12\" singles or albums. It narrows the Discogs search and decides which extra shots are asked for. Change it here, or say “forty-fives”, “twelve inch” or “albums”."),
        TourStep(anchor: .capture, tab: .scan, placement: .below, title: "AUTO OR MANUAL",
                 body: "AUTO fires on its own once the record is held steady. MANUAL never fires by itself — say “capture” or press space. Space forces a shot in either mode."),
        TourStep(anchor: .voice, tab: .scan, placement: .below, title: "VOICE STARTS OFF",
                 body: "Click VOICE when you want to talk to it. Recognition is on-device and the bottom bar lists the words that work. It mutes itself while reading a match back, so it never hears itself. Amber means it cannot start — hover for the reason. Settings can turn it on from launch."),
        TourStep(anchor: .rail, tab: .scan, placement: .leading, title: "THIS SESSION",
                 body: "The next record number, then a running list of what you have scanned. Thumbs up or down grades a match — a thumbs-down keeps it out of your Discogs Collection and logs it for tuning. The bottom row: Discogs rate, model spend, records waiting in REVIEW."),
        TourStep(anchor: .bottomBar, tab: .scan, placement: .above, title: "THE BOTTOM BAR",
                 body: "Switch cameras here — an iPhone nearby shows up as Continuity Camera and has better optics for small label type. Beside it, the voice words that work; on the right, shots taken this session."),
        TourStep(anchor: .library, tab: .library, placement: .inside, title: "LIBRARY",
                 body: "Everything catalogued, searchable by artist, title, label or catalogue number. Click a row for the tracklist, what was read from the photo and a link to the Discogs release. EXPORT CSV writes the whole collection to the output folder."),
        TourStep(anchor: .review, tab: .review, placement: .inside, title: "REVIEW",
                 body: "Records it could not identify wait here with their photo and whatever it managed to read. Type anything you know — artist, label, catalogue number, year — pick from the candidates, or save a manual entry."),
        TourStep(anchor: .settingsIdentification, tab: .settings, placement: .trailing, title: "IDENTIFICATION",
                 body: "Labels and catalogue numbers are read on the Mac for free. Pick a vision model and paste its key for artwork-heavy covers and picture sleeves. The spend line shows what this session has cost so far."),
        TourStep(anchor: .settingsDiscogs, tab: .settings, placement: .trailing, title: "DISCOGS",
                 body: "Your personal token lifts lookups to 60 a minute and lets matches be added to your Collection — switch that off to catalogue locally only. Values in the library are shown in the currency chosen here."),
        TourStep(anchor: .settingsVoice, tab: .settings, placement: .leading, title: "VOICE",
                 body: "Choose the microphone, whether matches are read aloud, the speech rate and the voice. LISTEN FROM LAUNCH turns the recogniser on every time the app opens; otherwise use the VOICE switch in the top bar."),
        TourStep(anchor: .settingsCapture, tab: .settings, placement: .leading, title: "CAPTURE",
                 body: "Camera, rotation and mirroring for the preview, saved per camera. The sliders set how steady, sharp and changed the scene must be before auto-capture fires — LIVE NUMBERS shows what the camera sees right now. Relearn the empty scene after moving the Mac."),
        TourStep(anchor: .settingsTests, tab: .settings, placement: .leading, title: "TESTS & DO-OVERS",
                 body: "Check the Discogs token and the model key from here. RUN SETUP AGAIN brings back the wizard; SHOW THE TOUR AGAIN brings back these callouts. That is the tour — DONE returns you to SCAN."),
    ]
}

/// Drives the tour: which step is showing, and switching the app to the tab that step lives on.
@MainActor
@Observable
final class TourState {
    private(set) var active = false
    private(set) var index = 0
    /// `--render-ui` sets this so the tour never pops up on its own while rendering.
    var suppressAutoStart = false
    weak var app: AppState?

    var completed: Bool { UserDefaults.standard.bool(forKey: "tourCompleted") }
    var step: TourStep? { active ? TourStep.all[index] : nil }
    var isLast: Bool { index == TourStep.all.count - 1 }

    func show(_ i: Int) {
        index = min(max(0, i), TourStep.all.count - 1)
        active = true
        app?.tab = TourStep.all[index].tab
    }
    func next() { isLast ? finish() : show(index + 1) }
    func back() { show(index - 1) }
    /// Skipping counts as done — the tour is one click away in Settings.
    func finish() {
        active = false
        UserDefaults.standard.set(true, forKey: "tourCompleted")
        app?.tab = .scan
    }
    /// Non-persisting dismiss for renders.
    func hide() { active = false }

    /// First time the main view appears after setup: wait for layout to settle, then start.
    func autoStartIfNeeded() async {
        guard !completed, !suppressAutoStart, !active else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, !active else { return }
        show(0)
    }
}

// MARK: - Anchors

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourAnchor: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as something the tour can point at.
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        // transform, not set: a plain anchorPreference would replace whatever anchors the subtree
        // already reported (the banner sits inside the preview pane).
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[anchor] = $1 }
    }
}

// MARK: - Layout (pure, exercised by SelfTest)

enum TourLayout {
    static let bubbleWidth: CGFloat = 380
    static let gap: CGFloat = 14
    static let margin: CGFloat = 12
    /// Enough vertical room for the tallest bubble; below that we flip sides.
    static let minHeight: CGFloat = 220

    struct Frame: Equatable {
        /// Region the bubble is aligned within; its width is always `bubbleWidth` except for `.inside`.
        var container: CGRect
        var alignment: Alignment
        /// Resolved side (a preferred side with no room falls back to the other one).
        var placement: TourStep.Placement
        /// Distance along the anchor-facing edge where the arrow sits.
        var arrow: CGFloat
    }

    static func place(anchor: CGRect, placement: TourStep.Placement, in size: CGSize) -> Frame {
        let bw = bubbleWidth
        func clampX(_ x: CGFloat) -> CGFloat { min(max(margin, x), max(margin, size.width - margin - bw)) }
        func arrowX(_ x: CGFloat) -> CGFloat { min(max(20, anchor.midX - x), bw - 20) }
        let roomBelow = size.height - anchor.maxY - gap - margin
        let roomAbove = anchor.minY - gap - margin
        let roomLeft = anchor.minX - gap - margin
        let roomRight = size.width - anchor.maxX - gap - margin

        var side = placement
        switch side {
        case .below where roomBelow < minHeight && roomAbove > roomBelow: side = .above
        case .above where roomAbove < minHeight && roomBelow > roomAbove: side = .below
        case .leading where roomLeft < bw: side = roomRight >= bw ? .trailing : (roomBelow >= roomAbove ? .below : .above)
        case .trailing where roomRight < bw: side = roomLeft >= bw ? .leading : (roomBelow >= roomAbove ? .below : .above)
        default: break
        }

        switch side {
        case .below:
            let x = clampX(anchor.midX - bw / 2)
            let y = anchor.maxY + gap
            return Frame(container: CGRect(x: x, y: y, width: bw, height: max(0, size.height - y - margin)), alignment: .top, placement: .below, arrow: arrowX(x))
        case .above:
            let x = clampX(anchor.midX - bw / 2)
            return Frame(container: CGRect(x: x, y: margin, width: bw, height: max(0, anchor.minY - gap - margin)), alignment: .bottom, placement: .above, arrow: arrowX(x))
        case .leading, .trailing:
            // Top-aligned with the anchor, nudged up when the anchor sits low; the arrow points at the anchor's top region.
            let y = min(max(margin, anchor.minY), max(margin, size.height - margin - minHeight))
            let x = side == .leading ? anchor.minX - gap - bw : anchor.maxX + gap
            let arrow = min(max(20, anchor.minY + 24 - y), 80)
            return Frame(container: CGRect(x: x, y: y, width: bw, height: max(0, size.height - y - margin)), alignment: .top, placement: side, arrow: arrow)
        case .inside:
            return Frame(container: anchor, alignment: .center, placement: .inside, arrow: 0)
        }
    }
}

// MARK: - Views

/// Sits over the main view (`overlayPreferenceValue`) and shows the current step, if any.
struct TourHost: View {
    @Environment(AppState.self) private var state
    let anchors: [TourAnchor: Anchor<CGRect>]

    var body: some View {
        if let step = state.tour.step {
            GeometryReader { geo in
                TourOverlay(step: step, anchorFrame: anchors[step.anchor].map { geo[$0] }, size: geo.size)
            }
        }
    }
}

struct TourOverlay: View {
    @Environment(AppState.self) private var state
    let step: TourStep
    let anchorFrame: CGRect?
    let size: CGSize

    var body: some View {
        let tour = state.tour
        // No anchor on screen (view not laid out yet): spotlight the middle so the bubble still reads.
        let hole = (anchorFrame ?? CGRect(x: size.width / 2 - 240, y: size.height / 2 - 120, width: 480, height: 240)).insetBy(dx: -6, dy: -6)
        let frame = TourLayout.place(anchor: hole, placement: step.placement, in: size)
        ZStack(alignment: .topLeading) {
            Theme.bg.opacity(0.72)
                .mask {
                    ZStack {
                        Rectangle()
                        RoundedRectangle(cornerRadius: 4).frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .contentShape(Rectangle())
                .onTapGesture {}   // swallows clicks so nothing underneath fires mid-tour
            RoundedRectangle(cornerRadius: 4).stroke(Theme.green, lineWidth: 2)
                .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY)
                .allowsHitTesting(false)
            TourBubble(step: step, index: tour.index, count: TourStep.all.count, frame: frame)
                .frame(width: frame.container.width, height: frame.container.height, alignment: frame.alignment)
                .offset(x: frame.container.minX, y: frame.container.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            // Keyboard: → / Return next, ← back, Esc leaves the tour.
            Group {
                Button("") { tour.next() }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { tour.next() }.keyboardShortcut(.defaultAction)
                Button("") { tour.back() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { tour.finish() }.keyboardShortcut(.cancelAction)
            }
            .hidden().frame(width: 0, height: 0)
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }
}

struct TourBubble: View {
    @Environment(AppState.self) private var state
    let step: TourStep
    let index: Int
    let count: Int
    let frame: TourLayout.Frame

    var body: some View {
        let tour = state.tour
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Caption("TOUR · \(index + 1) OF \(count)", color: Theme.green)
                Spacer()
                Caption(step.tab.rawValue)
            }
            Text(step.title).font(Theme.display(30)).lineLimit(2).minimumScaleFactor(0.7)
            Text(step.body).font(Theme.mono(13)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if index > 0 { WizardButton("BACK", style: .quiet) { tour.back() } }
                Spacer()
                if !tour.isLast { WizardButton("SKIP TOUR", style: .quiet) { tour.finish() } }
                WizardButton(tour.isLast ? "DONE" : "NEXT", style: .primary) { tour.next() }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: TourLayout.bubbleWidth)
        .foregroundStyle(Theme.text)   // the overlay sits outside the main view's foreground style
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.green).frame(height: 3) }
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .overlay { arrow }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    /// Small green wedge on the anchor-facing edge.
    @ViewBuilder private var arrow: some View {
        let a = frame.arrow
        switch frame.placement {
        case .below:
            Wedge().fill(Theme.green).frame(width: 18, height: 9).offset(x: a - 9, y: -9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .above:
            Wedge().fill(Theme.green).frame(width: 18, height: 9).rotationEffect(.degrees(180)).offset(x: a - 9, y: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        case .leading:
            Wedge().fill(Theme.green).frame(width: 18, height: 9).rotationEffect(.degrees(90)).offset(x: 13.5, y: a - 4.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        case .trailing:
            Wedge().fill(Theme.green).frame(width: 18, height: 9).rotationEffect(.degrees(-90)).offset(x: -13.5, y: a - 4.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .inside:
            EmptyView()
        }
    }
}

/// Upward-pointing triangle filling its frame.
private struct Wedge: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
