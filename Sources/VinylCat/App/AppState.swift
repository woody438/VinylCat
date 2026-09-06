import Foundation
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case scan = "SCAN", library = "LIBRARY", review = "REVIEW", settings = "SETTINGS"
    var id: String { rawValue }
}

/// Session-wide format default; drives Discogs search filters and the saved record.
enum VinylFormat: String, CaseIterable, Identifiable, Codable {
    case seven = "7\" SINGLES", twelve = "12\" SINGLES", lp = "ALBUMS"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppState {
    var tab: AppTab = .scan
    var format: VinylFormat = .seven
    var autoMode = true
    /// true = auto-capture when steady; false = manual ("capture" / space bar).
    var autoCapture: Bool = UserDefaults.standard.object(forKey: "autoCapture") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCapture, forKey: "autoCapture"); scan.setAutoCapture(autoCapture) }
    }
    var listening = false
    var sessionCount = 0
    var reviewCount = 0
    let camera = CameraSession()
    let scan: ScanController

    private var servicesStarted = false

    init(store: Store = .shared, photos: PhotoStore = .shared) {
        scan = ScanController(store: store, photos: photos)
        if let f = UserDefaults.standard.string(forKey: "defaultFormat"), let v = VinylFormat(rawValue: f) { format = v }
    }

    /// Whenever the camera changes, grab a diagnostic frame a moment later.
    private var lastCameraStatus = ""
    func noteCameraStatus() {
        let s = String(describing: camera.status)
        if s != lastCameraStatus {
            lastCameraStatus = s
            if case .running = camera.status {
                Task {
                    let mean = await scan.debugFrame()
                    // Black or silent stream (typical of a Continuity Camera that hasn't started) → try the next configuration.
                    if mean < 3, camera.escalate() { lastCameraStatus = "" }
                }
            }
        }
    }

    /// Camera, capture engine and voice. Idempotent; the wizard calls it when setup finishes.
    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        scan.appState = self
        scan.setAutoCapture(autoCapture)
        reviewCount = Store.shared.reviewCount()
        voice.onCommand = { [weak self] cmd in self?.scan.handle(command: cmd) }
        scan.speaker.onSpeakingChanged = { [weak self] speaking in self?.voice.muted = speaking }
        Task {
            await camera.start()
            scan.start(camera: camera)
            await voice.start()
        }
    }
    let identifier = Identifier()
    let discogs = DiscogsClient()
    let voice = SpeechCommands()
}
