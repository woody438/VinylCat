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
    @AppStorage("steadySeconds") private var steadySeconds = 0.6
    @AppStorage("sceneDeltaMin") private var sceneDeltaMin = 14.0
    @AppStorage("askForBSide") private var askForBSide = true
    @AppStorage("askForLabelsOnLP") private var askForLabelsOnLP = true
    @State private var testResult = ""

    var body: some View {
        @Bindable var identifier = state.identifier
        @Bindable var speaker = state.scan.speaker
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 32) {
                Section("IDENTIFICATION") {
                    Picker("", selection: $identifier.provider) {
                        ForEach(ReaderProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    KeyField(label: "OpenAI API key", text: $openAIKey) { Keychain.set(openAIKey, for: .openAI) }
                    KeyField(label: "Google AI key", text: $geminiKey) { Keychain.set(geminiKey, for: .gemini) }
                    Row("Skip model when barcode hits") { Toggle("", isOn: $identifier.skipModelWhenBarcode).labelsHidden().toggleStyle(.switch) }
                    Row("Spend this session") { Text(String(format: "$%.3f · %d reads", identifier.sessionCostUSD, identifier.reads)).foregroundStyle(Theme.secondary) }
                }
                Section("DISCOGS") {
                    Row("Username") { TextField("", text: $discogsUsername).textFieldStyle(.roundedBorder).frame(width: 170) }
                    KeyField(label: "Personal token", text: $discogsToken) { Keychain.set(discogsToken, for: .discogsToken) }
                    Row("Add matches to my Collection") { Toggle("", isOn: $discogsSync).labelsHidden().toggleStyle(.switch) }
                    Row("Valuation currency") {
                        Picker("", selection: $currency) { ForEach(["GBP", "USD", "EUR", "CAD"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 100)
                    }
                    Row("Rate limit") { Text(state.discogs.rateText).foregroundStyle(Theme.green) }
                }
            }
            VStack(alignment: .leading, spacing: 32) {
                Section("VOICE") {
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
                Section("CAPTURE") {
                    Row("Camera") {
                        @Bindable var camera = state.camera
                        Picker("", selection: $camera.selectedDeviceID) {
                            ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        }.labelsHidden().frame(width: 240)
                    }
                    Row("Relearn empty scene") { Button("Relearn now") { state.scan.relearnBaseline() } }
                    Row("Steady for") { HStack { Slider(value: $steadySeconds, in: 0.3...1.5).frame(width: 140); Text(String(format: "%.1f s", steadySeconds)).frame(width: 44) } }
                    Row("Sharpness needed") { HStack { Slider(value: $sharpnessMin, in: 20...200).frame(width: 140); Text("\(Int(sharpnessMin))").frame(width: 44) } }
                    Row("Scene change needed") { HStack { Slider(value: $sceneDeltaMin, in: 5...40).frame(width: 140); Text("\(Int(sceneDeltaMin))").frame(width: 44) } }
                    Row("Photos folder") { Text(PhotoStore.shared.root.path).foregroundStyle(Theme.secondary).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260) }
                    Row("Live numbers") { Text(state.scan.signal.map { String(format: "sharp %.0f · motion %.1f · scene %.0f · %@", $0.metrics.sharpness, $0.metrics.motion, $0.metrics.sceneDelta, $0.reason) } ?? "—").foregroundStyle(Theme.secondary) }
                }
            }
            VStack(alignment: .leading, spacing: 32) {
                Section("SHOTS") {
                    Row("Ask for the B-side on singles") { Toggle("", isOn: $askForBSide).labelsHidden().toggleStyle(.switch) }
                    Row("Ask for a label shot on LPs") { Toggle("", isOn: $askForLabelsOnLP).labelsHidden().toggleStyle(.switch) }
                    Text("LPs: front + back (+ label). 2×LP and gatefolds are detected from Discogs. Say “add photo”, “back cover”, “gatefold” or “disc two” for anything extra.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Section("TESTS") {
                    HStack(spacing: 12) {
                        Button("Test Discogs") { Task { testResult = await state.discogs.selfTest() } }
                        Button("Test model") { Task { testResult = await testModel() } }
                        Button("Run setup again") { UserDefaults.standard.set(false, forKey: "setupCompleted") }
                    }
                    Text(testResult).font(Theme.mono(12)).foregroundStyle(Theme.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
