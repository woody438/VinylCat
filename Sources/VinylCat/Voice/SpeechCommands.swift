@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Everything the operator can say. Phrases are matched as whole words at the end of the live transcript.
enum VoiceCommand: String, CaseIterable, Sendable {
    case capture, flip, skip, done, undo, review, again, one, two, three, none, yes, no
    case sevens, twelves, albums, pause, resume, addPhoto, backCover, gatefold, discTwo, addAnyway, label, autoMode, manualMode

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
        (.sevens, ["forty fives", "forty-fives", "forty five", "45s", "45's", "45 s", "seven inch", "seven inches", "singles", "sevens"]),
        (.twelves, ["twelve inch", "twelve inches", "twelves", "12 inch", "maxi"]),
        (.albums, ["albums", "album", "lps", "l p s", "long players"]),
        (.pause, ["pause", "stop listening", "hold on"]),
        (.resume, ["resume", "carry on", "continue"]),
        (.addPhoto, ["add photo", "extra photo", "another photo", "add a photo"]),
        (.backCover, ["back cover", "back", "rear"]),
        (.gatefold, ["gatefold", "inside"]),
        (.discTwo, ["disc two", "disc 2", "second disc", "record two"]),
        (.addAnyway, ["add anyway", "add it anyway", "keep both"]),
        (.autoMode, ["auto mode", "auto capture", "automatic"]),
        (.manualMode, ["manual mode", "manual", "manual capture"]),
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
    /// Chosen microphone (Core Audio UID); nil = system default. Persisted as "micUID".
    var micUID: String? = UserDefaults.standard.string(forKey: "micUID") {
        didSet { UserDefaults.standard.set(micUID, forKey: "micUID"); if wantListening { beginSession() } }
    }
    private(set) var inputs: [AudioInputs.Device] = []
    func refreshInputs() { inputs = AudioInputs.list() }
    var onCommand: ((VoiceCommand) -> Void)?
    /// While true (TTS speaking) microphone audio is not fed to the recogniser at all, so the app never hears itself.
    var muted = false { didSet { gate.muted = muted } }
    private let gate = AudioGate()
    private var sessionStart = Date()

    final class AudioGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _muted = false
        var muted: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _muted }
            set { lock.lock(); _muted = newValue; lock.unlock() }
        }
    }
    private var lastCommand: (VoiceCommand, Date)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped every time a session ends. A recognition callback carrying an older number belongs to
    /// a session we already tore down, and is dropped — see `handle(transcript:error:generation:)`.
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private var handledUpTo: TimeInterval = 0
    private var restartTimer: Task<Void, Never>?
    private var wantListening = false
    private var consecutiveFailures = 0
    private var lastLoggedLength = 0
    private var firedText = ""
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
        let gen = generation
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
        firedText = ""

        refreshInputs()
        if let uid = micUID, let dev = inputs.first(where: { $0.uid == uid }) {
            if !AudioInputs.select(dev, for: audioEngine) { Log.voice.error("could not select mic \(dev.name)") }
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { status = .error("No microphone input"); return }
        input.removeTap(onBus: 0)
        nonisolated(unsafe) let request = req
        let gate = self.gate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            if !gate.muted { request.append(buffer) }
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { status = .error(error.localizedDescription); return }
        // The input device changing under a running engine (a Continuity iPhone's microphone arriving
        // or leaving, AirPods connecting) stops the engine silently. Restart on the new device.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantListening, Date().timeIntervalSince(self.sessionStart) > 1 else { return }
                    Log.voice.info("audio configuration changed — restarting")
                    self.beginSession()
                }
            }
        }

        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            // Reduce the result to plain data before hopping to the main actor.
            let snapshot = result.map { r in
                Transcript(text: r.bestTranscription.formattedString,
                           segments: r.bestTranscription.segments.map { Segment(word: $0.substring, timestamp: $0.timestamp, duration: $0.duration) })
            }
            let message = error?.localizedDescription
            Task { @MainActor in self?.handle(transcript: snapshot, error: message, generation: gen) }
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

    private func scheduleRestart(after delay: Double) {
        restartTimer?.cancel()
        restartTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantListening else { return }
            self.beginSession()
        }
    }

    private func endSession() {
        generation += 1
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    struct Segment: Sendable { var word: String; var timestamp: TimeInterval; var duration: TimeInterval }
    struct Transcript: Sendable { var text: String; var segments: [Segment] }

    private func handle(transcript: Transcript?, error: String?, generation gen: Int) {
        // Cancelling a task makes it report an error ("canceled", or "No speech detected" if it had
        // heard only silence) a few milliseconds later — after the replacement session has already
        // started. Treating that as the new session failing restarted it again, which killed it
        // again, and so on until the give-up counter tripped and VOICE went dark for good.
        guard gen == generation else { return }
        if let error {
            let lived = Date().timeIntervalSince(sessionStart)
            let benign = error.localizedCaseInsensitiveContains("cancel") || error.localizedCaseInsensitiveContains("no speech")
            if benign, lived > 1, wantListening {
                // The recogniser closes a session on its own after a stretch of silence. Not a fault:
                // open the next one and keep the switch showing ON.
                Log.voice.debug("session ended after \(Int(lived)) s (\(error)) — reopening")
                scheduleRestart(after: 0.2)
                return
            }
            consecutiveFailures += 1
            status = .error(error)
            guard wantListening, consecutiveFailures <= 5 else { endSession(); return }
            scheduleRestart(after: min(10, Double(consecutiveFailures) * 2))
            return
        }
        consecutiveFailures = 0
        guard let result = transcript else { return }
        let segs = result.segments
        guard let last = segs.last else { return }
        lastHeard = result.text
        // Compare against the transcript we last acted on: only words beyond the common prefix are new.
        // (Timestamps are unreliable — the recogniser revises earlier words and re-emits them.)
        let words = result.text.split(separator: " ").map(String.init)
        let old = firedText.split(separator: " ").map(String.init)
        var common = 0
        while common < min(words.count, old.count), words[common].lowercased() == old[common].lowercased() { common += 1 }
        let fresh = Array(words.dropFirst(common))
        guard !fresh.isEmpty else { return }
        _ = last
        let tail = fresh.suffix(4).joined(separator: " ")
        if let cmd = VoiceCommand.match(trailing: tail) {
            firedText = result.text
            // The same word twice within 3 s is a revision ("Album" → "Albums") or an echo, not two commands.
            if let (prev, at) = lastCommand, prev == cmd, Date().timeIntervalSince(at) < 3 { return }
            lastCommand = (cmd, Date())
            Log.voice.info("command \(cmd.rawValue) from “\(tail)”")
            onCommand?(cmd)
        } else if result.text.count != lastLoggedLength {
            lastLoggedLength = result.text.count
            Log.voice.debug("heard “\(result.text.suffix(60))”")
        }
    }
}
