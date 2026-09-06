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
        (.undo, ["undo", "undo it", "undo that", "retake", "delete that", "go back", "scrap that"]),
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
    private(set) var status: Status = .idle { didSet { Log.voice.info("status \(String(describing: self.status))") } }
    private(set) var lastHeard = ""
    var onCommand: ((VoiceCommand) -> Void)?
    /// While true (TTS speaking), transcripts are ignored so the app doesn't hear itself. Words spoken during the mute
    /// can arrive from the recogniser *after* it ends, so both edges also discard everything up to "now".
    var muted = false {
        didSet { handledUpTo = max(handledUpTo, Date().timeIntervalSince(sessionStart)) }
    }
    private var sessionStart = Date()
    private var lastCommand: (VoiceCommand, Date)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handledUpTo: TimeInterval = 0
    private var restartTimer: Task<Void, Never>?
    private var wantListening = false
    private var consecutiveFailures = 0
    private var lastLoggedLength = 0
    /// Human hint for the top bar when listening isn't possible.
    var problem: String? {
        if case .error(let e) = status {
            if e.localizedCaseInsensitiveContains("dictation") { return "Turn on Dictation: System Settings → Keyboard → Dictation" }
            return e
        }
        if status == .unauthorized { return "Allow Microphone + Speech Recognition in System Settings → Privacy & Security" }
        return nil
    }

    func start() async {
        wantListening = true
        // These callbacks arrive on TCC's / Speech's own queues: keep them @Sendable so no main-actor isolation is assumed.
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in cont.resume(returning: status == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard speechOK, micOK else { status = .unauthorized; return }
        beginSession()
    }

    /// Try again from scratch (e.g. after the user turned Dictation on).
    func retry() async { consecutiveFailures = 0; await start() }

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
        sessionStart = Date()
        lastLoggedLength = 0

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { status = .error("No microphone input"); return }
        input.removeTap(onBus: 0)
        nonisolated(unsafe) let request = req
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in request.append(buffer) }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { status = .error(error.localizedDescription); return }

        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            // Reduce the result to plain data before hopping to the main actor.
            let snapshot = result.map { r in
                Transcript(text: r.bestTranscription.formattedString,
                           segments: r.bestTranscription.segments.map { Segment(word: $0.substring, timestamp: $0.timestamp, duration: $0.duration) })
            }
            let message = error?.localizedDescription
            Task { @MainActor in self?.handle(transcript: snapshot, error: message) }
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

    struct Segment: Sendable { var word: String; var timestamp: TimeInterval; var duration: TimeInterval }
    struct Transcript: Sendable { var text: String; var segments: [Segment] }

    private func handle(transcript: Transcript?, error: String?) {
        if let error {
            // Session roll-overs produce an error too; retry with backoff, give up after a few in a row.
            consecutiveFailures += 1
            status = .error(error)
            guard wantListening, consecutiveFailures <= 5 else { endSession(); return }
            let delay = min(10, Double(consecutiveFailures) * 2)
            restartTimer?.cancel()
            restartTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.wantListening else { return }
                self.beginSession()
            }
            return
        }
        consecutiveFailures = 0
        guard let result = transcript else { return }
        let segs = result.segments
        guard let last = segs.last else { return }
        lastHeard = result.text
        guard !muted else { handledUpTo = last.timestamp + last.duration; return }
        // Only look at words that arrived after the last command we acted on.
        let fresh = segs.filter { $0.timestamp >= handledUpTo }
        guard !fresh.isEmpty else { return }
        let tail = fresh.suffix(4).map(\.word).joined(separator: " ")
        if let cmd = VoiceCommand.match(trailing: tail) {
            handledUpTo = last.timestamp + last.duration + 0.01
            // The same word twice within 1.5 s is an echo or a stutter, not two commands.
            if let (prev, at) = lastCommand, prev == cmd, Date().timeIntervalSince(at) < 1.5 { return }
            lastCommand = (cmd, Date())
            Log.voice.info("command \(cmd.rawValue) from “\(tail)”")
            onCommand?(cmd)
        } else if result.text.count > lastLoggedLength {
            lastLoggedLength = result.text.count
            Log.voice.debug("heard “\(tail)”")
        }
    }
}
