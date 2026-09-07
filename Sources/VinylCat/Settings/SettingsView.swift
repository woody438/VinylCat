import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var openAIKey = Keychain.get(.openAI) ?? ""
    @State private var geminiKey = Keychain.get(.gemini) ?? ""
    @State private var discogsToken = Keychain.get(.discogsToken) ?? ""
    @AppStorage("discogsUsername") private var discogsUsername = ""
    @AppStorage("currency") private var currency = "GBP"
    @AppStorage("discogsSync") private var discogsSync = true
    @AppStorage("sharpnessMin") private var sharpnessMin = 60.0
    @AppStorage("steadySeconds") private var steadySeconds = 1.0
    @AppStorage("sceneDeltaMin") private var sceneDeltaMin = 14.0
    @AppStorage("askForBSide") private var askForBSide = false
    @AppStorage("askForFrontOnLP") private var askForFrontOnLP = false
    @AppStorage("askForCoversOnLP") private var askForCoversOnLP = false
    @AppStorage("askForLabelsOnLP") private var askForLabelsOnLP = false
    @State private var testResult = ""
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        // The three columns outgrow a short window; without a scroll container the content pushed
        // the top bar — and its tabs — off the top of the screen. (`--render-ui` can't draw a
        // ScrollView, so the headless renderer gets the bare columns.)
        if staticRender { columns } else { ScrollView { columns } }
    }

    private var columns: some View {
        @Bindable var identifier = state.identifier
        @Bindable var speaker = state.scan.speaker
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 32) {
                Section("IDENTIFICATION") {
                    Picker("", selection: $identifier.provider) {
                        ForEach(ReaderProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    KeyField(label: "OpenAI API key", text: $openAIKey) { Keychain.set(openAIKey, for: .openAI); identifier.refreshKeys() }
                    KeyField(label: "Google AI key", text: $geminiKey) { Keychain.set(geminiKey, for: .gemini); identifier.refreshKeys() }
                    Row("Skip model when barcode hits") { Toggle("", isOn: $identifier.skipModelWhenBarcode).labelsHidden().toggleStyle(.switch) }
                    Row("Spend this session") { Text(String(format: "$%.3f · %d reads", identifier.sessionCostUSD, identifier.reads)).foregroundStyle(Theme.secondary) }
                }
                .tourAnchor(.settingsIdentification)
                Section("DISCOGS") {
                    Row("Username") { TextField("", text: $discogsUsername).textFieldStyle(.roundedBorder).frame(width: 170) }
                    KeyField(label: "Personal token", text: $discogsToken) { Keychain.set(discogsToken, for: .discogsToken) }
                    Row("Add matches to my Collection") { Toggle("", isOn: $discogsSync).labelsHidden().toggleStyle(.switch) }
                    Row("Valuation currency") {
                        Picker("", selection: $currency) { ForEach(["GBP", "USD", "EUR", "CAD"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 100)
                    }
                    Row("Rate limit") { Text(state.discogs.rateText).foregroundStyle(Theme.green) }
                    Row("Pull my Collection") {
                        HStack(spacing: 8) {
                            Text(state.collectionSync.status).foregroundStyle(Theme.secondary).font(Theme.mono(11)).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                            Button(state.collectionSync.running ? "…" : "Pull now") { Task { await state.collectionSync.pull(discogs: state.discogs, store: Store.shared) } }
                                .disabled(state.collectionSync.running)
                        }
                    }
                    Text("Two-way: scans are added to your Discogs collection as they are saved, and a pull brings the rest of the collection into the Library (once at launch, and from here or the Library tab). Records removed on Discogs are unlinked here, never deleted.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .tourAnchor(.settingsDiscogs)
            }
            VStack(alignment: .leading, spacing: 32) {
                Section("VOICE") {
                    Row("Microphone") {
                        @Bindable var voice = state.voice
                        Picker("", selection: $voice.micUID) {
                            Text("System default").tag(String?.none)
                            ForEach(state.voice.inputs) { Text($0.name).tag(Optional($0.uid)) }
                        }.labelsHidden().frame(width: 240).onAppear { state.voice.refreshInputs() }
                    }
                    Row("Listen from launch") {
                        @Bindable var app = state
                        Toggle("", isOn: $app.voiceOnLaunch).labelsHidden().toggleStyle(.switch)
                    }
                    Row("Read out results") { Toggle("", isOn: $speaker.enabled).labelsHidden().toggleStyle(.switch) }
                    Row("Speech rate") { Slider(value: $speaker.rate, in: 0.35...0.65).frame(width: 160) }
                    Row("Voice") {
                        Picker("", selection: $speaker.voiceIdentifier) {
                            Text("Default (en-GB)").tag(String?.none)
                            ForEach(Speaker.availableVoices, id: \.identifier) { v in
                                Text("\(v.name) · \(v.language)").tag(Optional(v.identifier))
                            }
                        }.labelsHidden().frame(width: 240)
                    }
                    Row("Test") { Button("Say something") { state.scan.speaker.say("VinylCat ready. Hold up a record.") } }
                }
                .tourAnchor(.settingsVoice)
                Section("CAPTURE") {
                    Row("Camera") {
                        @Bindable var camera = state.camera
                        Picker("", selection: $camera.selectedDeviceID) {
                            ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        }.labelsHidden().frame(width: 240)
                    }
                    Row("Camera rotation") {
                        @Bindable var camera = state.camera
                        Picker("", selection: $camera.rotationOverride) {
                            Text("Auto").tag(Int?.none)
                            ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag(Optional($0)) }
                        }.labelsHidden().frame(width: 240)
                    }
                    Row("Mirror preview") {
                        @Bindable var camera = state.camera
                        Toggle("", isOn: $camera.mirrorPreview).labelsHidden().toggleStyle(.switch)
                    }
                    Text("Mirroring makes a sleeve moved left move left on screen, which is what you want from a camera pointing back at you. It affects the preview only — saved photos are never mirrored. On by default for built-in and USB cameras, off for a Continuity iPhone aimed at the records. Saved per camera.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text("An iPhone on Continuity Camera sends a landscape picture whichever way it is held. If the label comes out on its side, set 90° or 270°. Saved per camera.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Row("Relearn empty scene") { Button("Relearn now") { state.scan.relearnBaseline() } }
                    Row("Steady for") { HStack { Slider(value: $steadySeconds, in: 0.3...1.5).frame(width: 140); Text(String(format: "%.1f s", steadySeconds)).frame(width: 44) } }
                    Row("Sharpness needed") { HStack { Slider(value: $sharpnessMin, in: 20...200).frame(width: 140); Text("\(Int(sharpnessMin))").frame(width: 44) } }
                    Row("Scene change needed") { HStack { Slider(value: $sceneDeltaMin, in: 5...40).frame(width: 140); Text("\(Int(sceneDeltaMin))").frame(width: 44) } }
                    Row("Photos folder") { Text(PhotoStore.shared.root.path).foregroundStyle(Theme.secondary).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260) }
                    Row("Live numbers") { Text(state.scan.signal.map { String(format: "sharp %.0f · motion %.1f · scene %.0f · %@", $0.metrics.sharpness, $0.metrics.motion, $0.metrics.sceneDelta, $0.reason) } ?? "—").foregroundStyle(Theme.secondary) }
                }
                .tourAnchor(.settingsCapture)
            }
            VStack(alignment: .leading, spacing: 32) {
                Section("SHOTS") {
                    Row("Also photograph both labels on singles") { Toggle("", isOn: $askForBSide).labelsHidden().toggleStyle(.switch) }
                    Row("Also photograph the front cover on albums") { Toggle("", isOn: $askForFrontOnLP).labelsHidden().toggleStyle(.switch) }
                    Row("Also photograph the back cover on albums") { Toggle("", isOn: $askForCoversOnLP).labelsHidden().toggleStyle(.switch) }
                    Row("Also photograph a label on albums") { Toggle("", isOn: $askForLabelsOnLP).labelsHidden().toggleStyle(.switch) }
                    Text("After a confident match Discogs already knows the tracklist, the sleeve and the disc count, so the one photo it was identified from — cover or label — is enough for any format; the B-side is only asked for when a match is ambiguous. With these on, gatefolds get an inside shot and double albums a label per disc — both detected from Discogs. Say “flip”, “add photo”, “back cover”, “gatefold” or “disc two” for anything extra.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .tourAnchor(.settingsShots)
                Section("TESTS") {
                    HStack(spacing: 12) {
                        Button("Test Discogs") { Task { testResult = await state.discogs.selfTest() } }
                        Button("Test model") { Task { testResult = await testModel() } }
                        Button("Run setup again") { UserDefaults.standard.set(false, forKey: "setupCompleted") }
                        Button("Show the tour again") { state.tour.show(0) }
                    }
                    Text(testResult).font(Theme.mono(12)).foregroundStyle(Theme.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                .tourAnchor(.settingsTests)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: sharpnessMin) { _, _ in state.scan.applyTuning() }
        .onChange(of: steadySeconds) { _, _ in state.scan.applyTuning() }
        .onChange(of: sceneDeltaMin) { _, _ in state.scan.applyTuning() }
    }

    private func testModel() async -> String {
        guard let still = state.scan.lastStill else { return "Capture a photo on the Scan tab first." }
        do {
            let r = try await state.identifier.provider.reader.read(still, hints: .init())
            return "\(r.provider): \(r.reading.artist ?? "?") — \(r.reading.title ?? "?") · cat \(r.reading.catalogNumber ?? "?") · conf \(r.reading.confidence ?? 0) · $\(String(format: "%.4f", r.usage.costUSD))"
        } catch { return "Failed: \(error.localizedDescription)" }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.display(22)).tracking(2).padding(.bottom, 6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack {
            Text(label).font(Theme.mono(13)).foregroundStyle(Theme.muted)
            Spacer()
            content.font(Theme.mono(13))
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct KeyField: View {
    let label: String
    @Binding var text: String
    let save: () -> Void
    @State private var saved = false
    var body: some View {
        Row(label) {
            HStack(spacing: 8) {
                SecureField("paste key", text: $text).textFieldStyle(.roundedBorder).frame(width: 170)
                    .onSubmit { save(); saved = true }
                Button(saved ? "Saved" : "Save") { save(); saved = true }.fixedSize()
            }
        }
    }
}
