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
    /// Off by default: the recogniser only runs when VOICE is clicked, unless Settings says otherwise.
    var voiceOnLaunch: Bool = UserDefaults.standard.bool(forKey: "voiceOnLaunch") {
        didSet { UserDefaults.standard.set(voiceOnLaunch, forKey: "voiceOnLaunch") }
    }
    var sessionCount = 0
    var reviewCount = 0
    let camera = CameraSession()
    let scan: ScanController

    private var servicesStarted = false

    init(store: Store = .shared, photos: PhotoStore = .shared) {
        scan = ScanController(store: store, photos: photos)
        if let f = UserDefaults.standard.string(forKey: "defaultFormat"), let v = VinylFormat(rawValue: f) { format = v }
        tour.app = self
    }

    /// Once the camera delivers, sample its brightness so a running-but-black stream is reported
    /// rather than shown as a blank preview. The camera session itself handles "no frames at all".
    private var lastCameraStatus = ""
    private var brightnessTask: Task<Void, Never>?
    func noteCameraStatus() {
        let s = String(describing: camera.status)
        guard s != lastCameraStatus else { return }
        lastCameraStatus = s
        switch camera.status {
        case .running, .dark: startBrightnessMonitor()
        default: brightnessTask?.cancel(); brightnessTask = nil
        }
    }

    private func startBrightnessMonitor() {
        guard brightnessTask == nil else { return }
        brightnessTask = Task { [weak self] in
            // Keep sampling while the picture is black so it clears itself the moment the camera wakes up.
            while !Task.isCancelled {
                guard let self else { return }
                let mean = await scan.debugFrame()
                camera.reportBrightness(mean)
                if mean >= 3 { break }
                try? await Task.sleep(for: .seconds(3))
            }
            self?.brightnessTask = nil
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
            // The wizard's Dictation check may have left the recogniser running; launch state is "off" unless asked for.
            if voiceOnLaunch { await voice.start() } else if voice.status == .listening { voice.stop() }
        }
        // Prices follow the currency set on the Discogs profile; then the pull half of the sync.
        Task {
            await discogs.adoptProfileCurrency()
            if UserDefaults.standard.object(forKey: "discogsSync") as? Bool ?? true, Keychain.get(.discogsToken)?.nilIfEmpty != nil {
                await collectionSync.pull(discogs: discogs, store: Store.shared); reviewCount = Store.shared.reviewCount()
            }
        }
    }
    let collectionSync = CollectionSync()
    let identifier = Identifier()
    let discogs = DiscogsClient()
    let voice = SpeechCommands()
    let tour = TourState()
    /// The tip jar: free app, own keys, an ask that grows with the catalogue (see `Coffee`).
    let coffee = Coffee()
}
