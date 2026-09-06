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

    /// Camera, capture engine and voice. Idempotent; the wizard calls it when setup finishes.
    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        scan.appState = self
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
