import AppKit

/// Short audio cues, one per outcome. System sounds for now; custom AIFFs can replace them in Resources/Sounds.
enum Chime: String, CaseIterable {
    case captured = "Tink"
    case matched = "Glass"
    case ambiguous = "Ping"
    case needShot = "Pop"
    case notFound = "Basso"
    case duplicate = "Funk"

    @MainActor
    func play() {
        if let custom = Bundle.main.url(forResource: rawValue, withExtension: "aiff", subdirectory: "Sounds"),
           let s = NSSound(contentsOf: custom, byReference: true) {
            s.play(); return
        }
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}
