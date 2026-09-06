import AVFoundation
import Observation

/// Text-to-speech feedback. Interrupts itself so the latest prompt always wins.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var enabled = true
    var rate: Float = 0.52
    var voiceIdentifier: String?
    private(set) var isSpeaking = false
    /// Called on start/finish so the speech recogniser can mute itself.
    var onSpeakingChanged: ((Bool) -> Void)?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true; self.onSpeakingChanged?(true) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            // Short tail so the recogniser doesn't catch the end of our own sentence.
            try? await Task.sleep(for: .milliseconds(350))
            if !self.isSpeaking { self.onSpeakingChanged?(false) }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.onSpeakingChanged?(false) }
    }

    func say(_ text: String, interrupt: Bool = true) {
        guard enabled, !text.isEmpty else { return }
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        }
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    }
}
