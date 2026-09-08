import AppKit
import AVFoundation
import Speech
import SwiftUI

/// First-run wizard. Shown until `setupCompleted` is set; re-runnable from Settings.
struct SetupWizard: View {
    @Environment(AppState.self) private var state
    @Environment(\.previewSetupStep) private var previewStep
    @AppStorage("setupCompleted") private var setupCompleted = false
    @State private var step = 0
    let steps = ["WELCOME", "PERMISSIONS", "DISCOGS", "VISION MODEL", "PREFERENCES", "READY"]

    var body: some View {
        let current = previewStep ?? step
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                HStack(spacing: 10) {
                    LogoMark(disc: Color(hex: 0x2A2F34)).frame(width: 34, height: 34)
                    Text("VINYLCAT").font(Theme.display(26)).tracking(1.5)
                }
                Caption("SETUP")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        Text(s).font(Theme.mono(11)).tracking(1.5)
                            .foregroundStyle(i == current ? Theme.text : i < current ? Theme.green : Theme.muted)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(i == current ? Theme.green : .clear).frame(height: 2) }
                    }
                }
            }
            .padding(.horizontal, 24).frame(height: 56)
            Rectangle().fill(Theme.line).frame(height: 1)

            Group {
                switch current {
                case 0: WelcomeStep()
                case 1: PermissionsStep()
                case 2: DiscogsStep()
                case 3: ModelStep()
                case 4: PreferencesStep()
                default: ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(40)

            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                if current > 0 { WizardButton("BACK", style: .quiet) { step = max(0, step - 1) } }
                Spacer()
                if current < steps.count - 1 {
                    if current >= 2 && current <= 3 { WizardButton("SKIP FOR NOW", style: .quiet) { step += 1 } }
                    WizardButton("CONTINUE", style: .primary) { step += 1 }
                } else {
                    WizardButton("START SCANNING", style: .primary) {
                        setupCompleted = true
                        state.startServices()
                    }
                }
            }
            .padding(.horizontal, 24).frame(height: 64)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 20) {
                Text("HOLD UP A RECORD.\nTHAT'S IT.").font(Theme.display(64)).lineLimit(2)
                Text("VinylCat photographs each sleeve or label from the camera, identifies the release on Discogs, reads it back to you, asks for the B-side or back cover, and files it all in a local library — hands-free, by voice.")
                    .font(Theme.mono(15)).foregroundStyle(Theme.secondary).frame(maxWidth: 620)
                Text("Setup takes about five minutes. You'll need:").font(Theme.mono(13)).foregroundStyle(Theme.muted).padding(.top, 8)
                VStack(alignment: .leading, spacing: 10) {
                    Bullet("Camera, microphone and speech permissions — and macOS Dictation switched on.")
                    Bullet("A free Discogs account and personal token (so it can add records to your Collection). Optional: lookups work without one.")
                    Bullet("An OpenAI or Google AI key for reading artwork-heavy covers. Optional: labels and catalogue numbers work without one. Cost ≈ $2–4 per thousand records.")
                }
            }
            Spacer()
        }
    }
}

private struct PermissionsStep: View {
    @Environment(AppState.self) private var state
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var voiceChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("PERMISSIONS").font(Theme.display(44))
            Text("macOS will ask once for each. If you already said no, the button opens System Settings.").font(Theme.mono(13)).foregroundStyle(Theme.muted)
            PermissionRow(title: "Camera", detail: "to photograph sleeves and labels", ok: camera == .authorized, denied: camera == .denied || camera == .restricted,
                          allow: { Task { _ = await AVCaptureDevice.requestAccess(for: .video); camera = AVCaptureDevice.authorizationStatus(for: .video) } },
                          settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            PermissionRow(title: "Microphone", detail: "to hear commands like “capture” and “skip”", ok: mic == .authorized, denied: mic == .denied || mic == .restricted,
                          allow: { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); mic = AVCaptureDevice.authorizationStatus(for: .audio) } },
                          settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            PermissionRow(title: "Speech recognition", detail: "on-device, nothing leaves the Mac", ok: speech == .authorized, denied: speech == .denied || speech == .restricted,
                          allow: { SFSpeechRecognizer.requestAuthorization { @Sendable s in Task { @MainActor in speech = s } } },
                          settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            let listening = state.voice.status == .listening
            PermissionRow(title: "Dictation", detail: listening ? "speech recogniser is live" : (state.voice.problem ?? "macOS needs Dictation on for speech recognition to work — System Settings → Keyboard → Dictation"),
                          ok: listening, denied: voiceChecked && !listening,
                          allow: { voiceChecked = true; Task { await state.voice.retry() } },
                          settings: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation", allowTitle: "CHECK")
            Text("Tip: an iPhone nearby appears as a second camera and microphone (Continuity Camera) — better optics for small label type. Pick them on the Preferences step.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
    }
}

private struct PermissionRow: View {
    let title: String, detail: String, ok: Bool, denied: Bool
    let allow: () -> Void
    let settings: String
    var allowTitle = "ALLOW"
    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(ok ? Theme.green : denied ? Theme.red : Theme.muted).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(Theme.display(22))
                Text(detail).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            if ok { Caption("GRANTED", color: Theme.green) }
            else if denied { WizardButton("OPEN SYSTEM SETTINGS", style: .quiet) { if let u = URL(string: settings) { NSWorkspace.shared.open(u) } } }
            else { WizardButton(allowTitle, style: .primary, action: allow) }
        }
        .padding(16).frame(maxWidth: 760).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

private struct DiscogsStep: View {
    @Environment(AppState.self) private var state
    @State private var token = Keychain.get(.discogsToken) ?? ""
    @State private var result = ""
    @State private var busy = false
    @AppStorage("discogsUsername") private var username = ""
    @AppStorage("discogsSync") private var sync = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DISCOGS").font(Theme.display(44))
            Text("Discogs is the database every record is matched against. A free personal token lifts the lookup limit to 60/min and lets VinylCat add matches to your Collection.").font(Theme.mono(13)).foregroundStyle(Theme.secondary).frame(maxWidth: 700)
            VStack(alignment: .leading, spacing: 10) {
                Bullet("1.  Create a free account at discogs.com (if you don't have one).")
                Bullet("2.  Generate a personal access token (any name, e.g. “VinylCat”):")
                WizardButton("OPEN DISCOGS.COM/SETTINGS/DEVELOPERS", style: .quiet) { NSWorkspace.shared.open(URL(string: "https://www.discogs.com/settings/developers")!) }.padding(.leading, 20)
                Bullet("3.  Paste it here and test.")
            }
            HStack(spacing: 12) {
                SecureField("paste token", text: $token).textFieldStyle(.roundedBorder).frame(width: 360).font(Theme.mono(13))
                WizardButton(busy ? "TESTING…" : "SAVE & TEST", style: .primary) {
                    Keychain.set(token, for: .discogsToken)
                    busy = true
                    Task { result = await state.discogs.selfTest(); username = UserDefaults.standard.string(forKey: "discogsUsername") ?? ""; busy = false }
                }
            }
            if !result.isEmpty { Text(result).font(Theme.mono(12)).foregroundStyle(result.hasPrefix("OK") ? Theme.green : Theme.red).frame(maxWidth: 700) }
            Toggle(isOn: $sync) { Text("Add every matched record to my Discogs Collection").font(Theme.mono(13)) }.toggleStyle(.switch).tint(Theme.green)
            Text("Without a token: lookups still work at 25/min, nothing is written to Discogs.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
    }
}

private struct ModelStep: View {
    @Environment(AppState.self) private var state
    @State private var openAI = Keychain.get(.openAI) ?? ""
    @State private var gemini = Keychain.get(.gemini) ?? ""
    @State private var result = ""
    @State private var busy = false

    var body: some View {
        @Bindable var identifier = state.identifier
        VStack(alignment: .leading, spacing: 20) {
            Text("VISION MODEL").font(Theme.display(44))
            Text("Labels and catalogue numbers are read on the Mac for free. A vision model adds artwork-heavy covers and picture sleeves. Pick one, paste its key, test it. Optional — skip and add later in Settings.").font(Theme.mono(13)).foregroundStyle(Theme.secondary).frame(maxWidth: 720)
            Picker("", selection: $identifier.provider) {
                ForEach(ReaderProvider.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.radioGroup)
            if identifier.provider == .luna {
                HStack(spacing: 6) {
                    Text("GPT-5.6 Luna · about $0.001 per photo · key from").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    Link("platform.openai.com/api-keys", destination: URL(string: "https://platform.openai.com/api-keys")!).font(Theme.mono(12)).underline().foregroundStyle(Theme.green)
                }
                HStack(spacing: 12) {
                    SecureField("sk-…", text: $openAI).textFieldStyle(.roundedBorder).frame(width: 360)
                    WizardButton(busy ? "TESTING…" : "SAVE & TEST", style: .primary) { Keychain.set(openAI, for: .openAI); state.identifier.refreshKeys(); Task { await test() } }
                    WizardButton("GET A KEY", style: .quiet) { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!) }
                }
            } else {
                HStack(spacing: 6) {
                    Text("Gemini 3.8 Flash · about $0.002 per photo · key from").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    Link("aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!).font(Theme.mono(12)).underline().foregroundStyle(Theme.green)
                }
                HStack(spacing: 12) {
                    SecureField("AIza…", text: $gemini).textFieldStyle(.roundedBorder).frame(width: 360)
                    WizardButton(busy ? "TESTING…" : "SAVE & TEST", style: .primary) { Keychain.set(gemini, for: .gemini); state.identifier.refreshKeys(); Task { await test() } }
                    WizardButton("GET A KEY", style: .quiet) { NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!) }
                }
            }
            if !result.isEmpty { Text(result).font(Theme.mono(12)).foregroundStyle(result.hasPrefix("OK") ? Theme.green : Theme.red).frame(maxWidth: 720) }
            Text("Keys are stored in the macOS Keychain and never leave this Mac except to call the provider you chose.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
    }

    private func test() async {
        busy = true; defer { busy = false }
        // A synthetic label so the test costs a fraction of a cent and needs no camera.
        guard let img = SetupWizard.testLabelImage() else { result = "Could not build a test image"; return }
        do {
            let r = try await state.identifier.provider.reader.read(img, hints: .init(sessionFormat: "seven inch singles", expectLabel: true))
            result = "OK — \(r.provider) read: \(r.reading.artist ?? "?") — \(r.reading.title ?? "?") · \(r.reading.catalogNumber ?? "?") · cost $\(String(format: "%.4f", r.usage.costUSD))"
        } catch { result = "Failed: \(error.localizedDescription)" }
    }
}

private struct PreferencesStep: View {
    @Environment(AppState.self) private var state
    @AppStorage("currency") private var currency = "GBP"
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("defaultFormat") private var defaultFormat = VinylFormat.seven.rawValue

    var body: some View {
        @Bindable var camera = state.camera
        @Bindable var speaker = state.scan.speaker
        @Bindable var voice = state.voice
        VStack(alignment: .leading, spacing: 22) {
            Text("PREFERENCES").font(Theme.display(44))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow {
                    Text("Values in").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    Picker("", selection: $currency) { ForEach(["GBP", "USD", "EUR", "CAD", "AUD"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 120)
                }
                GridRow {
                    Text("Start each session on").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    Picker("", selection: $defaultFormat) { ForEach(VinylFormat.allCases) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden().frame(width: 180)
                }
                GridRow {
                    Text("Camera").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    Picker("", selection: $camera.selectedDeviceID) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }.labelsHidden().frame(width: 260)
                }
                GridRow {
                    Text("Microphone").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    Picker("", selection: $voice.micUID) {
                        Text("System default").tag(String?.none)
                        ForEach(state.voice.inputs) { Text($0.name).tag(Optional($0.uid)) }
                    }.labelsHidden().frame(width: 260)
                }
                GridRow {
                    Text("Voice").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                    HStack {
                        Picker("", selection: $speaker.voiceIdentifier) {
                            Text("Default (en-GB)").tag(String?.none)
                            ForEach(Speaker.availableVoices, id: \.identifier) { v in Text("\(v.name) · \(v.language)").tag(Optional(v.identifier)) }
                        }.labelsHidden().frame(width: 260)
                        WizardButton("HEAR IT", style: .quiet) { state.scan.speaker.say("The Jam, Going Underground, 1980, seven inch. Now the B-side.") }
                    }
                }
            }
            Toggle(isOn: $autoCapture) { Text("Auto-capture when a record is held steady (off = say “capture” or press space)").font(Theme.mono(13)) }.toggleStyle(.switch).tint(Theme.green)
            Text("Gatefolds and double albums are detected from Discogs: with the extras on, they get an inside shot and a label per disc. Everything here can be changed later in Settings.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
        .onAppear { state.camera.refreshDevices(); state.voice.refreshInputs() }
    }
}

private struct ReadyStep: View {
    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 20) {
                Text("READY.").font(Theme.display(64))
                VStack(alignment: .leading, spacing: 12) {
                    Bullet("Put the Mac where you can hold a record about 40 cm from the camera, on a plain background.")
                    Bullet("Set the format in the top bar — or say “forty-fives”, “twelve inch”, “albums”.")
                    Bullet("Line the cover or label up in the guide and hold still for a second — or say “capture” / press space. Chime = captured.")
                    Bullet("Voice starts off. Click VOICE in the top bar when you want to talk to it (Settings → LISTEN FROM LAUNCH keeps it on).")
                    Bullet("Listen: it reads the match back, then asks for the B-side or back cover. Flip, hold, chime, next record.")
                    Bullet("Can't identify it? It's parked in REVIEW with the photo — finish it later by voice or typing.")
                    Bullet("VinylCat is free and runs on your own keys. As the catalogue grows it will ask, now and then, for a coffee — \(Coffee.handle). Saying no is allowed. Saying yes ends the asking.")
                }
                Text("The bottom bar always lists the words that work right now.").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Caption("VOICE")
                ForEach([("capture", "force a shot"), ("flip · B-side · back cover · gatefold · disc two", "take that shot"), ("skip / done", "move on / finish record"), ("undo", "retake or delete"), ("one · two · three · none", "pick a candidate"), ("review", "park it"), ("again", "retake the ID shot"), ("pause / resume", "auto-capture")], id: \.0) { w, d in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("“\(w)”").font(Theme.mono(13)).foregroundStyle(Theme.green).frame(width: 300, alignment: .leading)
                        Text(d).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(20).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
    }
}

// MARK: - Bits

private struct Bullet: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Rectangle().fill(Theme.green).frame(width: 8, height: 8).offset(y: -2)
            Text(text).font(Theme.mono(13)).foregroundStyle(Theme.secondary).frame(maxWidth: 680, alignment: .leading)
        }
    }
}

struct WizardButton: View {
    enum Style { case primary, quiet }
    let title: String
    let style: Style
    let action: () -> Void
    init(_ title: String, style: Style, action: @escaping () -> Void) { self.title = title; self.style = style; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.mono(12)).tracking(1.5)
                .foregroundStyle(style == .primary ? Theme.bg : Theme.secondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(style == .primary ? Theme.green : .clear)
                .overlay(Rectangle().stroke(style == .primary ? Theme.green : Theme.raised, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

extension SetupWizard {
    /// Renders a fake 7" label ("POLYDOR · POSP 113 · GOING UNDERGROUND · THE JAM") to test a model key without a camera.
    static func testLabelImage() -> CGImage? {
        let size = NSSize(width: 800, height: 800)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.3, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill(); NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 760, height: 760)).fill()
        NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 200, y: 200, width: 400, height: 400)).fill()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        for (i, (line, sz)) in [("POLYDOR", 26), ("POSP 113", 20), ("45 RPM", 16), ("GOING UNDERGROUND", 22), ("THE JAM", 26), ("SIDE A", 14)].enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(sz), weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para]
            let y: CGFloat = i < 3 ? 540 - CGFloat(i) * 34 : 330 - CGFloat(i - 3) * 34
            (line as NSString).draw(in: NSRect(x: 250, y: y, width: 300, height: 32), withAttributes: attrs)
        }
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

struct PreviewSetupStepKey: EnvironmentKey { static let defaultValue: Int? = nil }
extension EnvironmentValues {
    var previewSetupStep: Int? {
        get { self[PreviewSetupStepKey.self] }
        set { self[PreviewSetupStepKey.self] = newValue }
    }
}
