@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Everything the operator can say. Phrases are matched as whole words at the end of the live transcript.
enum VoiceCommand: String, CaseIterable, Sendable {
    case capture, flip, skip, done, undo, review, again, one, two, three, none, yes, no
    case sevens, twelves, albums, pause, resume, addPhoto, backCover, gatefold, discTwo, addAnyway, label

    static let phrases: [(VoiceCommand, [String])] = [
        (.capture, ["capture", "take it", "shoot", "snap"]),
        (.flip, ["flip", "flip it", "b side", "b-side", "other side"]),
        (.label, ["label", "show label", "the label"]),
        (.skip, ["skip", "skip it", "next"]),
        (.done, ["done", "finished", "that's it"]),
        (.undo, ["undo", "retake", "delete that"]),
        (.review, ["review", "review later", "park it", "later"]),
        (.again, ["again", "try again", "retry"]),
        (.one, ["one", "number one", "first", "1"]),
        (.two, ["two", "number two", "second", "2"]),
        (.three, ["three", "number three", "third", "3"]),
        (.none, ["none", "none of those", "neither"]),
        (.yes, ["yes", "yep", "correct"]),
        (.no, ["no", "nope", "wrong"]),
        (.sevens, ["forty fives", "forty-fives", "seven inch", "singles", "sevens"]),
        (.twelves, ["twelve inch", "twelves", "maxi"]),
        (.albums, ["albums", "album", "lps", "l p s", "long players"]),
        (.pause, ["pause", "stop listening", "hold on"]),
        (.resume, ["resume", "carry on", "continue"]),
        (.addPhoto, ["add photo", "extra photo", "another photo", "add a photo"]),
        (.backCover, ["back cover", "back", "rear"]),
        (.gatefold, ["gatefold", "inside"]),
        (.discTwo, ["disc two", "disc 2", "second disc", "record two"]),
        (.addAnyway, ["add anyway", "add it anyway", "keep both"]),
    ]

    static var contextualStrings: [String] { phrases.flatMap(\.1) }

    /// Match the trailing words of a transcript. Longest phrase wins.
    static func match(trailing text: String) -> VoiceCommand? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var best: (VoiceCommand, Int)?
        for (cmd, list) in phrases {
            for p in list where t == p || t.hasSuffix(" " + p) {
                if best == nil || p.count > best!.1 { best = (cmd, p.count) }
            }
        }
        return best?.0
    }
}

/// On-device continuous speech recognition that emits `VoiceCommand`s.
@MainActor
@Observable
final class SpeechCommands {
    enum Status: Equatable { case idle, unauthorized, listening, error(String) }
    private(set) var status: Status = .idle
    private(set) var lastHeard = ""
    var onCommand: ((VoiceCommand) -> Void)?
    /// While true (TTS speaking), transcripts are ignored so the app doesn't hear itself.
    var muted = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handledUpTo: TimeInterval = 0
    private var restartTimer: Task<Void, Never>?
    private var wantListening = false

    func start() async {
        wantListening = true
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard speechOK, micOK else { status = .unauthorized; return }
        beginSession()
    }

    func stop() {
        wantListening = false
        restartTimer?.cancel()
        endSession()
        status = .idle
    }

    private func beginSession() {
        endSession()
        guard let recognizer, recognizer.isAvailable else { status = .error("Speech recogniser unavailable"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.contextualStrings = VoiceCommand.contextualStrings
        req.taskHint = .search
        request = req
        handledUpTo = 0

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { status = .error("No microphone input"); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in req.append(buffer) }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { status = .error(error.localizedDescription); return }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in self?.handle(result: result, error: error) }
        }
        status = .listening

        // Recognition sessions degrade after a while; roll over every 45 s.
        restartTimer?.cancel()
        restartTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.wantListening else { return }
            self.beginSession()
        }
    }

    private func endSession() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            // Common when a session rolls over; restart if we still want to listen.
            if wantListening { status = .error(error.localizedDescription); beginSession() }
            return
        }
        guard let result else { return }
        let segs = result.bestTranscription.segments
        guard let last = segs.last else { return }
        lastHeard = result.bestTranscription.formattedString
        guard !muted else { handledUpTo = last.timestamp + last.duration; return }
        // Only look at words that arrived after the last command we acted on.
        let fresh = segs.filter { $0.timestamp >= handledUpTo }
        guard !fresh.isEmpty else { return }
        let tail = fresh.suffix(4).map(\.substring).joined(separator: " ")
        if let cmd = VoiceCommand.match(trailing: tail) {
            handledUpTo = last.timestamp + last.duration + 0.01
            onCommand?(cmd)
        }
    }
}
