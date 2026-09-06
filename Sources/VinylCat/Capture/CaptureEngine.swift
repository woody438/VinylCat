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
    /// Hamming distance the frame may drift during the steady window before the timer restarts.
    var steadyHashDrift: Int = 6
    /// Hamming distance below which a new steady frame is "the same item we just shot".
    var sameItemHash: Int = 10
    /// Scene must drop back near the baseline (or change this much from the last shot) before re-arming.
    var rearmDelta: Double = 12
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
    private var steadySince: Date?
    private var steadyHash: UInt64?
    /// false = manual mode: keep analysing (ring, hints) but never fire on our own; "capture"/space still works.
    private var autoCapture = true
    private var lastCaptureHash: UInt64?
    private var cooldown = false
    private var enabled = true
    private var forceNext = false
    private var latestFrame: Frame?
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

    func setEnabled(_ on: Bool) { enabled = on; if !on { steadySince = nil } }
    func setAutoCapture(_ on: Bool) { autoCapture = on; steadySince = nil }
    func setTuning(_ t: CaptureTuning) { tuning = t }
    /// Voice "capture": take the next sharp frame regardless of the steady timer.
    func forceCapture() { forceNext = true }
    /// Re-arm immediately (e.g. after "again" / "undo"), ignoring cooldown.
    func rearm() { cooldown = false; steadySince = nil; needMotion = false }
    func setMode(_ m: Mode) {
        mode = m
        if m == .shot { cooldown = false; needMotion = true; steadySince = nil }
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
        let grey = analyzer.greyscale(frame.pixelBuffer)
        let m = analyzer.analyze(grey)

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

        let present = m.sceneDelta >= tuning.sceneDeltaMin
        let still = m.motion <= tuning.motionMax
        let sharp = m.sharpness >= tuning.sharpnessMin
        guard present else { steadySince = nil; emit(m, 0, true, "empty"); return }
        guard still else { steadySince = nil; emit(m, 0, true, "moving"); return }
        guard sharp else { steadySince = nil; emit(m, 0, true, "blurry"); return }

        let now = Date()
        // The steady window restarts if the content itself changes (a record sliding through looks "still" frame-to-frame).
        if steadySince == nil || steadyHash.map({ FrameAnalyzer.hammingDistance($0, m.hash) > tuning.steadyHashDrift }) ?? true {
            steadySince = now; steadyHash = m.hash
        }
        let progress = min(1, now.timeIntervalSince(steadySince!) / tuning.steadySeconds)
        guard autoCapture else { emit(m, progress, true, progress >= 1 ? "ready — say capture" : "steady"); return }
        if progress >= 1 {
            if mode == .identify, let h = lastCaptureHash, FrameAnalyzer.hammingDistance(h, m.hash) <= tuning.sameItemHash {
                emit(m, 1, false, "same item"); return
            }
            capture(frame, m, forced: false)
        } else {
            emit(m, progress, true, "steady")
        }
    }

    private func capture(_ frame: Frame, _ m: FrameMetrics, forced: Bool) {
        steadySince = nil
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
