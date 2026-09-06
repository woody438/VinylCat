import AVFoundation
import CoreImage
import Foundation
import Observation

/// Tunables surfaced in Settings later.
struct CaptureTuning: Sendable {
    var sharpnessMin: Double = 60
    var motionMax: Double = 4
    var sceneDeltaMin: Double = 14
    var steadySeconds: Double = 1.0
    /// How far the picture may drift (mean abs difference, 0–255) during the steady window before it
    /// counts as a different item and the window restarts.
    var contentDriftMax: Double = 11
    /// Hamming distance below which a new steady frame is "the same item we just shot".
    var sameItemHash: Int = 10
    /// Scene must drop back near the baseline (or change this much from the last shot) before re-arming.
    var rearmDelta: Double = 12
    /// Once the hold has started, thresholds relax by this fraction — a record that was good enough a
    /// moment ago stays good enough through a wobble, instead of flipping in and out on every frame.
    var slack: Double = 0.5
    /// The steady window drains this many times slower than it fills, so a brief blur dents the ring
    /// rather than resetting it. 1.0 would make it symmetrical.
    var decayRate: Double = 0.35
}

/// What the engine reports to the HUD every frame.
struct CaptureSignal: Sendable {
    var metrics: FrameMetrics
    var steadyProgress: Double   // 0…1 as the steady timer fills
    var armed: Bool
    var reason: String           // short human hint: "steady", "blurry", "moving", "empty", "cooldown"
}

/// A still worth keeping. Full-resolution CGImage plus the metrics that triggered it.
struct CapturedStill: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
    let metrics: FrameMetrics
    let forced: Bool
}

/// Watches the frame stream and decides when a record is being held steady in front of the camera.
/// State machine: armed → (steady timer fills) → capture → cooldown until the scene changes → armed.
actor CaptureEngine {
    /// identify: wait for the record to be removed/swapped before re-arming (no double scans).
    /// shot: re-arm immediately but require the record to be moved (flipped) before the next capture.
    enum Mode: Sendable { case identify, shot }
    private var mode: Mode = .identify
    private var needMotion = false

    private let analyzer = FrameAnalyzer()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var tuning: CaptureTuning
    /// Seconds of accumulated hold, 0…steadySeconds. Fills while the shot is good, drains while it
    /// is not — the ring is this over steadySeconds, which is why it now moves instead of snapping.
    private var steadyCredit: Double = 0
    /// The thumbnail the current hold started from, to notice the item itself changing.
    private var steadyReference: [UInt8]?
    private var driftFrames = 0
    /// Consecutive qualifying frames — a hold has to be seen, not just timed.
    private var goodFrames = 0
    private var absentFrames = 0
    private var lastTick: Double?
    /// false = manual mode: keep analysing (ring, hints) but never fire on our own; "capture"/space still works.
    private var autoCapture = true
    private var lastCaptureHash: UInt64?
    private var cooldown = false
    private var enabled = true
    /// While true the engine analyses but never fires on its own: the HUD is waiting for the
    /// operator to answer something. "capture" / space still force a shot.
    private var holding = false
    private var forceNext = false
    private var latestFrame: Frame?
    private var debugSaveAt: Int?
    private var frameCount = 0
    private var debugCont: CheckedContinuation<Int, Never>?
    /// Saves the frame that arrives `frames` from now as a JPEG and returns its mean brightness (0 = black).
    /// Returns -1 if no frame arrives within 4 s (the device is not delivering at all).
    func saveDebugFrame(after frames: Int = 20) async -> Int {
        debugSaveAt = frameCount + frames
        return await withCheckedContinuation { cont in
            debugCont = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.timeoutDebug()
            }
        }
    }
    private func timeoutDebug() { if let c = debugCont { debugCont = nil; debugSaveAt = nil; c.resume(returning: -1); Log.capture.info("debug frame: no frames arrived in 4 s") } }
    private var baselineFrames = 0

    private let signalCont: AsyncStream<CaptureSignal>.Continuation
    nonisolated let signals: AsyncStream<CaptureSignal>
    private let stillCont: AsyncStream<CapturedStill>.Continuation
    nonisolated let stills: AsyncStream<CapturedStill>

    init(tuning: CaptureTuning = .init()) {
        self.tuning = tuning
        var sc: AsyncStream<CaptureSignal>.Continuation!
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { sc = $0 }
        signalCont = sc
        var stc: AsyncStream<CapturedStill>.Continuation!
        stills = AsyncStream(bufferingPolicy: .unbounded) { stc = $0 }
        stillCont = stc
    }

    func setEnabled(_ on: Bool) { enabled = on; if !on { resetHold() } }
    /// Stop (or resume) firing on our own while a question is on screen.
    func setHold(_ on: Bool) { holding = on; resetHold(); if !on { cooldown = false; needMotion = false } }
    func setAutoCapture(_ on: Bool) { autoCapture = on; resetHold() }
    func setTuning(_ t: CaptureTuning) { tuning = t }
    /// Voice "capture": take the next sharp frame regardless of the steady timer.
    func forceCapture() { forceNext = true }
    /// Re-arm immediately (e.g. after "again" / "undo"), ignoring cooldown.
    func rearm() { cooldown = false; resetHold(); needMotion = false }
    func setMode(_ m: Mode) {
        mode = m
        if m == .shot { cooldown = false; needMotion = true; resetHold() }
    }
    /// Forget the empty-scene reference; the next few quiet frames become the new one.
    func relearnBaseline() { analyzer.resetBaseline(); baselineFrames = 0 }

    /// Pump frames in. Runs for the life of the camera session.
    func run(frames: AsyncStream<Frame>) async {
        for await frame in frames {
            latestFrame = frame
            process(frame)
        }
    }

    private func process(_ frame: Frame) {
        frameCount += 1
        let grey = analyzer.greyscale(frame.pixelBuffer)
        let m = analyzer.analyze(grey)
        if let at = debugSaveAt, frameCount >= at {
            debugSaveAt = nil
            let mean = grey.reduce(0) { $0 + Int($1) } / max(1, grey.count)
            let ci = CIImage(cvPixelBuffer: frame.pixelBuffer)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                let url = try? PhotoStore(root: PhotoStore.shared.root.deletingLastPathComponent()).save(cg, name: "debug-frame", maxSide: 800)
                Log.capture.info("debug frame \(CVPixelBufferGetWidth(frame.pixelBuffer))x\(CVPixelBufferGetHeight(frame.pixelBuffer)) mean \(mean) sharp \(Int(m.sharpness)) → \(url?.lastPathComponent ?? "not saved")")
            }
            if let c = debugCont { debugCont = nil; c.resume(returning: mean) }
        }

        // Learn the empty scene from the first ~1 s of still frames after start / relearn.
        if !analyzer.hasBaseline() {
            baselineFrames += 1
            if m.motion < tuning.motionMax && baselineFrames > 5 { analyzer.setBaseline(from: grey) }
            emit(m, 0, false, "learning")
            return
        }

        guard enabled else { emit(m, 0, false, "paused"); return }

        if forceNext {
            forceNext = false
            capture(frame, m, forced: true)
            return
        }

        if holding { emit(m, 0, false, "waiting for your answer"); return }

        if needMotion {
            if m.motion > tuning.motionMax * 3 { needMotion = false } else { emit(m, 0, false, "flip it"); return }
        }

        if cooldown {
            // Wait for the record to be taken away (scene back near empty) or clearly swapped.
            let swapped = lastCaptureHash.map { FrameAnalyzer.hammingDistance($0, m.hash) > tuning.sameItemHash + 8 } ?? true
            if m.sceneDelta < tuning.sceneDeltaMin || (swapped && m.motion < tuning.motionMax) {
                cooldown = false
            } else {
                emit(m, 0, false, "cooldown"); return
            }
        }

        let dt = tick()
        // Once the hold has started the bars are lower: a shot that qualified a moment ago keeps
        // qualifying through a wobble. Without this the frame-to-frame noise alone crossed the
        // thresholds constantly and the HUD strobed between ARMED and STEADY.
        let holding = steadyCredit > 0
        let ease = holding ? tuning.slack : 0
        let present = m.sceneDelta >= tuning.sceneDeltaMin * (1 - ease)
        let still = m.motion <= tuning.motionMax * (1 + ease * 2)
        let sharp = m.sharpness >= tuning.sharpnessMin * (1 - ease)

        // Nothing in front of the camera is a real reset — but only once it has been empty for a
        // few frames, so a dark label or a shadow dipping the scene delta doesn't dump the hold.
        if !present {
            absentFrames += 1
            if absentFrames >= 3 { resetHold(); emit(m, 0, true, "empty"); return }
            emit(m, steadyCredit / tuning.steadySeconds, true, "steady"); return
        }
        absentFrames = 0

        // A record sliding through looks "still" frame-to-frame, so compare against the picture the
        // hold started from, and only believe a change that lasts more than one frame.
        if let ref = steadyReference, holding {
            if analyzer.drift(ref, grey) > tuning.contentDriftMax {
                driftFrames += 1
                if driftFrames >= 3 { resetHold() }
            } else {
                driftFrames = 0
            }
        }
        if steadyCredit == 0 { steadyReference = grey; driftFrames = 0 }

        guard still && sharp else {
            goodFrames = 0
            steadyCredit = max(0, steadyCredit - dt * tuning.decayRate)
            let progress = steadyCredit / tuning.steadySeconds
            // While there is credit left the HUD keeps saying "steady" — the ring dipping is the
            // feedback, not a change of state.
            emit(m, progress, true, progress > 0 ? "steady" : (still ? "blurry" : "moving"))
            return
        }

        goodFrames += 1
        steadyCredit = min(tuning.steadySeconds, steadyCredit + dt)
        let progress = steadyCredit / tuning.steadySeconds
        guard autoCapture else { emit(m, progress, true, progress >= 1 ? "ready — say capture" : "steady"); return }
        if progress >= 1 && goodFrames >= 3 {
            if mode == .identify, let h = lastCaptureHash, FrameAnalyzer.hammingDistance(h, m.hash) <= tuning.sameItemHash {
                emit(m, 1, false, "same item"); return
            }
            capture(frame, m, forced: false)
        } else {
            emit(m, progress, true, "steady")
        }
    }

    /// Seconds since the previous frame, clamped so a stalled camera or a debugger pause can't
    /// dump a whole second of credit into the ring at once.
    private func tick() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        guard let last = lastTick else { return 1.0 / 30 }
        // Capped at a frame-and-a-bit: a stalled stream or a resumed app must not hand the ring a
        // whole hold's worth of credit in one frame.
        return min(1.0 / 15, max(0, now - last))
    }

    private func resetHold() {
        steadyCredit = 0
        goodFrames = 0
        absentFrames = 0
        steadyReference = nil
        driftFrames = 0
    }

    private func capture(_ frame: Frame, _ m: FrameMetrics, forced: Bool) {
        resetHold()
        cooldown = mode == .identify
        needMotion = mode == .shot
        lastCaptureHash = m.hash
        let ci = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        stillCont.yield(CapturedStill(image: cg, capturedAt: Date(), metrics: m, forced: forced))
        emit(m, 1, false, "captured")
    }

    private func emit(_ m: FrameMetrics, _ p: Double, _ armed: Bool, _ reason: String) {
        signalCont.yield(CaptureSignal(metrics: m, steadyProgress: p, armed: armed, reason: reason))
    }
}
