@preconcurrency import AVFoundation
import CoreImage
import Observation

/// One captured video frame. CVPixelBuffer is not Sendable; frames are only ever read, never mutated.
struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
}

/// Holds the AVCaptureSession. All configuration happens on `queue`; the preview layer only reads it.
final class CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.woodall.vinylcat.capture", qos: .userInitiated)
}

/// Receives frames from AVFoundation on the capture queue and forwards them to an AsyncStream.
/// Also counts deliveries so the session can tell "warming up" from "never going to stream".
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<Frame>.Continuation
    private let lock = NSLock()
    private var count = 0
    var delivered: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(continuation: AsyncStream<Frame>.Continuation) { self.continuation = continuation }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); count &+= 1; lock.unlock()
        continuation.yield(Frame(pixelBuffer: pb, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
}

@MainActor
@Observable
final class CameraSession {
    enum Status: Equatable {
        case idle
        case unauthorized
        case noCamera
        /// Session started, no frames yet. Continuity Camera takes seconds to hand the stream over.
        case warmingUp(String)
        case running(String)
        /// Frames are arriving but every pixel is black — the other Continuity failure mode
        /// (iPhone face-down or lens covered, Continuity paused on the phone, camera held by another app).
        case dark(String)
        case failed(String)
    }

    private(set) var status: Status = .idle { didSet { Log.camera.info("status \(String(describing: self.status))") } }
    private(set) var devices: [AVCaptureDevice] = []
    var selectedDeviceID: String? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            if let id = selectedDeviceID { UserDefaults.standard.set(id, forKey: Self.deviceIDKey) }
            if oldValue != nil { restart() }
        }
    }
    static let deviceIDKey = "cameraDeviceID"

    let box = CaptureBox()
    /// Downscaled BGRA frames for analysis (~15 fps). Consumed by the capture engine.
    let frames: AsyncStream<Frame>
    private let sink: FrameSink
    private let output = AVCaptureVideoDataOutput()
    private var discovery: AVCaptureDevice.DiscoverySession?
    /// Configuration attempt for the current device: 0 = session preset, 1 = explicit ≤1080p format and
    /// no pixel-format request. Escalated once if the first attempt never delivers a frame.
    private(set) var attempt = 0
    private var restartDevice: AVCaptureDevice?
    /// Generation counter so a watchdog from an abandoned configuration stops talking.
    private var generation = 0
    /// The live preview layer, registered by CameraPreviewView so rotation can be applied to it.
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Follows the physical orientation of the capture device — an iPhone on Continuity Camera is
    /// usually held portrait, and without this its video arrives on its side.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    /// Display aspect (w/h) when the video does not fill the panel, so the alignment guide can follow
    /// the letterboxed picture instead of the whole view. nil while the video fills the panel.
    private(set) var videoAspect: CGFloat?

    /// Fixed rotation for the current camera, in degrees, or nil to follow the device automatically.
    /// Stored per camera: the built-in one never needs turning, an iPhone held portrait always does.
    var rotationOverride: Int? {
        didSet {
            guard oldValue != rotationOverride, let id = selectedDeviceID else { return }
            let key = "cameraRotation.\(id)"
            if let r = rotationOverride { UserDefaults.standard.set(r, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            applyRotation()
        }
    }

    private func loadRotationOverride(for device: AVCaptureDevice) {
        let stored = UserDefaults.standard.object(forKey: "cameraRotation.\(device.uniqueID)") as? Int
        if stored != rotationOverride { rotationOverride = stored }
    }

    /// Called by the preview view once its layer exists.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        // Every mutation of the session goes through `queue`. Attaching the layer adds a connection,
        // so doing it on the main thread while configure() is running crashes AVFoundation
        // ("collection was mutated while being enumerated" inside startRunning).
        let box = self.box
        box.queue.async { layer.session = box.session }
        // Rebuild the coordinator now the layer exists — it levels the preview against that layer.
        if let device = restartDevice { startRotationTracking(device: device) } else { applyRotation() }
    }

    init() {
        var cont: AsyncStream<Frame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        sink = FrameSink(continuation: cont)
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: box.session, queue: .main) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.camera.error("session runtime error \(err?.localizedDescription ?? "?") (\(err?.code ?? 0))")
        }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .unauthorized; return }
        default: status = .unauthorized; return
        }
        refreshDevices()
        Log.camera.info("devices \(self.devices.map { "\($0.localizedName) [\($0.uniqueID)]" })")
        guard let device = currentDevice() else { status = .noCamera; return }
        selectedDeviceID = device.uniqueID
        configure(device: device)
    }

    func refreshDevices() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        discovery = d
        devices = d.devices
    }

    private func currentDevice() -> AVCaptureDevice? {
        if let id = selectedDeviceID, let d = devices.first(where: { $0.uniqueID == id }) { return d }
        if let saved = UserDefaults.standard.string(forKey: Self.deviceIDKey),
           let d = devices.first(where: { $0.uniqueID == saved }) { return d }
        return devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func restart() {
        refreshDevices()
        guard let device = currentDevice() else { status = .noCamera; return }
        attempt = 0
        configure(device: device)
    }

    private func configure(device: AVCaptureDevice) {
        let box = self.box
        let output = self.output
        let sink = self.sink
        let name = device.localizedName
        restartDevice = device
        let attempt = self.attempt
        generation &+= 1
        let generation = self.generation
        status = .warmingUp(name)
        startRotationTracking(device: device)
        Log.camera.info("switching to \(name) · type \(device.deviceType.rawValue) · connected \(device.isConnected) · suspended \(device.isSuspended) · inUseElsewhere \(device.isInUseByAnotherApplication) · format \(device.activeFormat.formatDescription.dimensions.width)x\(device.activeFormat.formatDescription.dimensions.height) · \(device.formats.count) formats")
        box.queue.async { [weak self] in
            let session = box.session
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for out in session.outputs { session.removeOutput(out) }
            var failure: Error?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
                if attempt == 0 {
                    if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                } else {
                    // Explicit format: pick the largest ≤1080p format the device offers and lock it in.
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    let candidates = device.formats.filter { $0.formatDescription.dimensions.height <= 1080 }
                    if let best = candidates.max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }) {
                        try device.lockForConfiguration()
                        device.activeFormat = best
                        if let r = best.videoSupportedFrameRateRanges.first { device.activeVideoMinFrameDuration = r.minFrameDuration; device.activeVideoMaxFrameDuration = r.minFrameDuration }
                        device.unlockForConfiguration()
                        Log.camera.info("attempt \(attempt): format \(best.formatDescription.dimensions.width)x\(best.formatDescription.dimensions.height) \(best.formatDescription.mediaSubType)")
                    }
                }
                session.addInput(input)
                // Always BGRA: FrameAnalysis reads the buffer as BGRA, so a native-format stream would be noise.
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(sink, queue: box.queue)
                guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
                session.addOutput(output)
            } catch { failure = error }
            // Commit BEFORE starting: startRunning() inside begin/commit throws an ObjC exception.
            session.commitConfiguration()
            if let failure {
                Task { @MainActor in self?.status = .failed(failure.localizedDescription) }
                return
            }
            guard !session.inputs.isEmpty else { Task { @MainActor in self?.status = .failed("No camera input") }; return }
            // A Continuity Camera can vanish mid-configuration; starting on a dead input throws.
            guard device.isConnected else { Task { @MainActor in self?.status = .failed("\(name) disconnected.") }; return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                guard running else { self.status = .failed("Camera did not start"); return }
                await self.awaitFirstFrame(device: device, name: name, generation: generation)
            }
        }
    }

    /// A Continuity Camera hands its stream over lazily — the iPhone has to wake, and that can take
    /// the better part of ten seconds. Wait for a real frame before declaring anything; only then
    /// escalate. Tearing the session down early just restarts the handover and it never completes.
    private func awaitFirstFrame(device: AVCaptureDevice, name: String, generation: Int) async {
        let isContinuity = device.deviceType == .continuityCamera
        let grace: Double = isContinuity ? 20 : 6
        let start = sink.delivered
        let began = Date()
        while Date().timeIntervalSince(began) < grace {
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == self.generation else { return }
            if sink.delivered > start {
                Log.camera.info("first frame from \(name) after \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
                status = .running(name)
                // Re-read orientation now the device is live; a Continuity Camera reports nothing
                // meaningful until it is actually streaming.
                startRotationTracking(device: device)
                return
            }
        }
        Log.camera.info("no frames from \(name) in \(Int(grace)) s · suspended \(device.isSuspended) · inUseElsewhere \(device.isInUseByAnotherApplication) · session running \(box.session.isRunning)")
        if attempt == 0 {
            attempt = 1
            configure(device: device)
        } else {
            status = .failed(isContinuity ? continuityAdvice(device) : "\(name) is connected but sending no video.")
        }
    }

    private func continuityAdvice(_ device: AVCaptureDevice) -> String {
        if device.isInUseByAnotherApplication { return "Your iPhone's camera is in use by another app. Quit it and pick the camera again." }
        return """
        \(device.localizedName) is connected but sending no video. Continuity Camera only streams when the iPhone is locked, \
        still, and propped with the rear cameras facing out — near the Mac, Wi-Fi and Bluetooth on. Check it works in \
        FaceTime or QuickTime (New Movie Recording), then pick the camera again here.
        """
    }

    private func startRotationTracking(device: AVCaptureDevice) {
        rotationObservations.removeAll()
        loadRotationOverride(for: device)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in
                Task { @MainActor in self?.applyRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture) { [weak self] _, _ in
                Task { @MainActor in self?.applyRotation() }
            },
        ]
        applyRotation()
    }

    /// Rotates preview and frames so the picture is upright however the phone is held, and lets a
    /// portrait picture show whole rather than being cropped to a strip by aspect-fill.
    private func applyRotation() {
        guard let coordinator = rotationCoordinator else { return }
        // A fixed override wins: Continuity Camera does not always report which way the phone is held.
        let manual = rotationOverride.map(CGFloat.init)
        let preview = manual ?? coordinator.videoRotationAngleForHorizonLevelPreview
        let capture = manual ?? coordinator.videoRotationAngleForHorizonLevelCapture
        let quarterTurned = preview.truncatingRemainder(dividingBy: 180) != 0
        let native = restartDevice?.activeFormat.formatDescription.dimensions
        let w = CGFloat(native?.width ?? 16), h = CGFloat(native?.height ?? 9)
        let shown = quarterTurned ? h / w : w / h
        previewLayer?.videoGravity = shown < 1 ? .resizeAspect : .resizeAspectFill
        videoAspect = shown < 1 ? shown : nil
        if lastRotation?.preview != preview || lastRotation?.capture != capture {
            lastRotation = (preview: preview, capture: capture)
            Log.camera.info("rotation preview \(Int(preview))° capture \(Int(capture))° (\(manual == nil ? "auto" : "manual")) · showing \(String(format: "%.2f", shown)):1")
        }
        let output = self.output
        let layer = previewLayer
        box.queue.async {
            if let connection = layer?.connection, connection.isVideoRotationAngleSupported(preview) {
                connection.videoRotationAngle = preview
            }
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(capture) {
                connection.videoRotationAngle = capture
            }
        }
    }
    private var lastRotation: (preview: CGFloat, capture: CGFloat)?

    /// The capture engine reports how bright the stream is; a running-but-pitch-black stream is
    /// worth saying out loud rather than showing as a blank preview. Recovers by itself.
    func reportBrightness(_ mean: Int) {
        guard mean >= 0 else { return }
        switch status {
        case .running(let name): if mean < 3 { Log.camera.info("\(name) is streaming but black (mean \(mean))"); status = .dark(name) }
        case .dark(let name): if mean >= 3 { status = .running(name) }
        default: break
        }
    }

    var darkStreamAdvice: String {
        guard let d = restartDevice else { return "The camera is sending a black picture." }
        if d.deviceType == .continuityCamera { return continuityDarkAdvice(d) }
        return "\(d.localizedName) is sending a black picture. Check nothing is covering the lens."
    }

    private func continuityDarkAdvice(_ device: AVCaptureDevice) -> String {
        """
        \(device.localizedName) is connected but every frame is black. Continuity Camera only shows a picture when the \
        iPhone is locked, still, and propped with the rear cameras facing out — flat on a desk or in a pocket gives \
        exactly this. Check the iPhone's screen for a Pause button, and confirm it works in QuickTime Player → \
        New Movie Recording before blaming VinylCat.
        """
    }

    func stop() {
        let box = self.box
        generation &+= 1
        rotationObservations.removeAll()
        rotationCoordinator = nil
        box.queue.async { if box.session.isRunning { box.session.stopRunning() } }
        status = .idle
    }

    enum CameraError: LocalizedError {
        case cannotAddInput, cannotAddOutput
        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "Could not attach the camera."
            case .cannotAddOutput: "Could not attach the video output."
            }
        }
    }
}
