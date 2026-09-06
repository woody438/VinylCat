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
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<Frame>.Continuation
    init(continuation: AsyncStream<Frame>.Continuation) { self.continuation = continuation }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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
        case running(String)
        case failed(String)
    }

    private(set) var status: Status = .idle { didSet { Log.camera.info("status \(String(describing: self.status))") } }
    private(set) var devices: [AVCaptureDevice] = []
    var selectedDeviceID: String? {
        didSet { if oldValue != selectedDeviceID, oldValue != nil { restart() } }
    }

    let box = CaptureBox()
    /// Downscaled BGRA frames for analysis (~15 fps). Consumed by the capture engine.
    let frames: AsyncStream<Frame>
    private let sink: FrameSink
    private let output = AVCaptureVideoDataOutput()
    private var discovery: AVCaptureDevice.DiscoverySession?

    init() {
        var cont: AsyncStream<Frame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        sink = FrameSink(continuation: cont)
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .unauthorized; return }
        default: status = .unauthorized; return
        }
        refreshDevices()
        Log.camera.info("devices \(self.devices.map(\.localizedName))")
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
        return devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func restart() {
        refreshDevices()
        guard let device = currentDevice() else { status = .noCamera; return }
        configure(device: device)
    }

    private func configure(device: AVCaptureDevice) {
        let box = self.box
        let output = self.output
        let sink = self.sink
        let name = device.localizedName
        box.queue.async { [weak self] in
            let session = box.session
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for out in session.outputs { session.removeOutput(out) }
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            var failure: Error?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
                session.addInput(input)
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
            session.startRunning()
            Task { @MainActor in self?.status = session.isRunning ? .running(name) : .failed("Camera did not start") }
        }
    }

    func stop() {
        let box = self.box
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
