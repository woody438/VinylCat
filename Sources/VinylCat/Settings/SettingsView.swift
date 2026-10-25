import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var openAIKey = Keychain.get(.openAI) ?? ""
    @State private var geminiKey = Keychain.get(.gemini) ?? ""
    @State private var anthropicKey = Keychain.get(.anthropic) ?? ""
    @State private var discogsToken = Keychain.get(.discogsToken) ?? ""
    @AppStorage("claudeModel") private var claudeModel: ClaudeModel = .opus
    @AppStorage("discogsUsername") private var discogsUsername = ""
    @AppStorage("currency") private var currency = "GBP"
    @AppStorage("discogsSync") private var discogsSync = false
    @AppStorage("sharpnessMin") private var sharpnessMin = 60.0
    @AppStorage("steadySeconds") private var steadySeconds = 1.0
    @AppStorage("sceneDeltaMin") private var sceneDeltaMin = 14.0
    @AppStorage("launchPing") private var launchPing = true
    @State private var testResult = ""
    @State private var reporting = false
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
            VStack(alignment: .leading, spacing: 24) {
                Section("IDENTIFICATION") {
                    Picker("", selection: $identifier.provider) {
                        ForEach(ReaderProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    KeyField(label: "OpenAI API key", text: $openAIKey) { Keychain.set(openAIKey, for: .openAI); identifier.refreshKeys() }
                    KeyField(label: "Google AI key", text: $geminiKey) { Keychain.set(geminiKey, for: .gemini); identifier.refreshKeys() }
                    if identifier.provider == .claude {
                        Row("Claude model") {
                            Picker("", selection: $claudeModel) {
                                ForEach(ClaudeModel.allCases) { Text($0.short).tag($0) }
                            }.labelsHidden().frame(width: 150)
                        }
                        Text(claudeModel.note).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        Text(ClaudeModel.costAdvice(withLedger: true)).font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Text(AnthropicCredential.statusLine()).font(Theme.mono(11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        KeyField(label: "Anthropic API key", text: $anthropicKey) { Keychain.set(anthropicKey, for: .anthropic); identifier.refreshKeys() }
                    }
                    Row("Skip model when barcode hits") { Toggle("", isOn: $identifier.skipModelWhenBarcode).labelsHidden().toggleStyle(.switch) }
                    Row("Spend this session") { Text(String(format: "$%.3f · %d reads", identifier.sessionCostUSD, identifier.reads)).foregroundStyle(Theme.secondary) }
                    Row("Spend this month") {
                        Text(String(format: "$%.2f · %d reads", identifier.spend.monthCostUSD, identifier.spend.monthReads))
                            .foregroundStyle(identifier.overBudget ? Theme.amber : Theme.secondary)
                    }
                    Row("Warn me past") {
                        HStack(spacing: 6) {
                            TextField("", value: $identifier.monthlyBudgetUSD, format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                            Text("USD a month · 0 never").foregroundStyle(Theme.muted).font(Theme.mono(11))
                        }
                    }
                }
                .tourAnchor(.settingsIdentification)
                Section("DISCOGS") {
                    Row("Username") { TextField("", text: $discogsUsername).textFieldStyle(.roundedBorder).frame(width: 170) }
                    KeyField(label: "Personal token", text: $discogsToken) { Keychain.set(discogsToken, for: .discogsToken) }
                    Row("Add matches to my Collection") { Toggle("", isOn: $discogsSync).labelsHidden().toggleStyle(.switch) }
                    Row("Valuation currency") {
                        HStack(spacing: 8) {
                            if UserDefaults.standard.bool(forKey: "currencyFromProfile") { Text("from your Discogs profile").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                            Picker("", selection: $currency) { ForEach(["GBP", "USD", "EUR", "CAD", "AUD", "JPY", "CHF", "SEK", "NZD", "MXN", "ZAR", "BRL"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 100)
                        }
                    }
                    .help("Follows the currency on your Discogs profile at launch; change it here for this session only.")
                    Row("Rate limit") { Text(state.discogs.rateText).foregroundStyle(Theme.green) }
                    Row("Pull my Collection") {
                        HStack(spacing: 8) {
                            Text(state.collectionSync.status).foregroundStyle(Theme.secondary).font(Theme.mono(11)).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                            Button(state.collectionSync.running ? "…" : "Pull now") { Task { await state.collectionSync.pull(discogs: state.discogs, store: Store.shared) } }
                                .disabled(state.collectionSync.running)
                        }
                    }
                    Text("Two-way: scans go up as they are saved; a pull (at launch, here, or in the Library) brings the rest down. Removed on Discogs = unlinked here, never deleted.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .tourAnchor(.settingsDiscogs)
                // Column one ends soonest, so the card doesn't push Settings into scrolling.
                Section("UPDATES") { UpdatesSettings() }
            }
            VStack(alignment: .leading, spacing: 24) {
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
                    Text("Mirror affects the preview only, never the saved photo. Label on its side from an iPhone? Set 90° or 270°. Both saved per camera.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        .help("Mirroring makes a sleeve moved left move left on screen — what you want from a camera pointing back at you. On by default for built-in and USB cameras, off for a Continuity iPhone aimed at the records. An iPhone on Continuity Camera sends a landscape picture whichever way it is held.")
                    Row("Relearn empty scene") { Button("Relearn now") { state.scan.relearnBaseline() } }
                    Row("Steady for") { HStack { Slider(value: $steadySeconds, in: 0.3...1.5).frame(width: 140); Text(String(format: "%.1f s", steadySeconds)).frame(width: 44) } }
                    Row("Sharpness needed") { HStack { Slider(value: $sharpnessMin, in: 20...200).frame(width: 140); Text("\(Int(sharpnessMin)) focus").frame(width: 80, alignment: .trailing) } }
                    Row("Scene change needed") { HStack { Slider(value: $sceneDeltaMin, in: 5...40).frame(width: 140); Text("\(Int(sceneDeltaMin)) of 255").frame(width: 80, alignment: .trailing) } }
                    Text("The gauges below go green once each number clears its slider.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        .help("Focus is the edge-contrast score of the frame (blurry < 40, crisp > 120). Scene change is how far the picture is from the empty scene on a 0–255 grey scale.")
                    Row("Photos folder") { Text(PhotoStore.shared.root.path).foregroundStyle(Theme.secondary).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260) }
                    // Its own block, not a Row: squeezed into a Row's trailing slot the labels wrapped one letter per line.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Live from the camera").font(Theme.mono(13)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(state.scan.signal?.reason ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                        }
                        SignalGauges(metrics: state.scan.signal?.metrics, tuning: CaptureTuning.fromDefaults(), showNumbers: true, stacked: true)
                    }
                    .padding(.vertical, 8)
                }
                .tourAnchor(.settingsCapture)
                // Under the gauges: the shortest column, so the card never pushes Settings into scrolling.
                Section("SUPPORT") { CoffeeSettings() }
            }
            VStack(alignment: .leading, spacing: 24) {
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
                Section("PHOTOS") {
                    Text("One photo per record, the one it was identified from. For more, press F (B-side) or P (add a photo), or say “flip”, “back cover”, “gatefold” or “disc two” after a scan.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Section("TESTS") {
                    // A grid, so the buttons wrap in a narrow window instead of truncating to "Run setup ag…".
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 10) {
                        Button("Test Discogs") { Task { testResult = await state.discogs.selfTest() } }.frame(maxWidth: .infinity)
                        Button("Test model") { Task { testResult = await testModel() } }.frame(maxWidth: .infinity)
                        Button("Run setup again") { UserDefaults.standard.set(false, forKey: "setupCompleted") }.frame(maxWidth: .infinity)
                        Button("Show the tour again") { state.tour.show(0) }.frame(maxWidth: .infinity)
                    }
                    Text(testResult).font(Theme.mono(12)).foregroundStyle(Theme.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                .tourAnchor(.settingsTests)
                Section("ABOUT") {
                    Row("Version") { Text(BuildInfo.version).foregroundStyle(Theme.secondary) }
                    Row("Build") { Text(BuildInfo.build).foregroundStyle(Theme.secondary).font(Theme.mono(11)) }
                    Row("Model spend, all time") { Text(String(format: "$%.2f · %d reads", identifier.spend.totalCostUSD, identifier.spend.totalReads)).foregroundStyle(Theme.secondary) }
                    Row("Count launches") { Toggle("", isOn: $launchPing).labelsHidden().toggleStyle(.switch) }
                    Text("On: each launch sends the word “launch” and the version number to vinyl-cat.com, nothing else, so the developer can see whether anyone uses it. No identifier, no IP kept.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Row("Something wrong?") {
                        Button("REPORT A PROBLEM") { reporting = true }.buttonStyle(.plain).foregroundStyle(Theme.amber)
                    }
                    Text("Say what happened and send it, with the app's recent log if you like; it lands with the developer as a ticket. For a wrong match, use REPORT on the record in the Library so its scan evidence goes too.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: sharpnessMin) { _, _ in state.scan.applyTuning() }
        .onChange(of: steadySeconds) { _, _ in state.scan.applyTuning() }
        .onChange(of: sceneDeltaMin) { _, _ in state.scan.applyTuning() }
        .sheet(isPresented: $reporting) { BugReportSheet(record: nil) { reporting = false }.environment(state) }
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
        .padding(.vertical, 5)
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
