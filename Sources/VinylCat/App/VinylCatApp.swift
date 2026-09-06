import SwiftUI

@main
struct VinylCatApp: App {
    @State private var state = AppState()

    init() {
        // `VinylCat --self-test` runs the built-in checks and exits (no Xcode/XCTest needed).
        if CommandLine.arguments.contains("--self-test") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
    }

    var body: some Scene {
        WindowGroup("VinylCat") {
            RootView()
                .environment(state)
                .frame(minWidth: 1200, minHeight: 760)
                .background(Theme.bg)
                .preferredColorScheme(.dark)
                .task {
                    state.scan.appState = state
                    state.reviewCount = Store.shared.reviewCount()
                    state.voice.onCommand = { [weak state] cmd in state?.scan.handle(command: cmd) }
                    state.scan.speaker.onSpeakingChanged = { [weak state] speaking in state?.voice.muted = speaking }
                    await state.camera.start()
                    state.scan.start(camera: state.camera)
                    await state.voice.start()
                    state.listening = state.voice.status == .listening
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.line)
            switch state.tab {
            case .scan: ScanView()
            case .library: LibraryView()
            case .review: ReviewView()
            case .settings: SettingsView()
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }
}

struct Placeholder: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.display(40))
            Caption("COMING IN A LATER PHASE")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TopBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 24) {
            Text("VINYLCAT").font(Theme.display(26)).tracking(1.5)
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    let active = state.tab == tab
                    let title = tab == .review && state.reviewCount > 0 ? "REVIEW · \(state.reviewCount)" : tab.rawValue
                    Text(title)
                        .font(Theme.mono(13)).tracking(1.5)
                        .foregroundStyle(active ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(active ? Theme.green : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                        .onTapGesture { state.tab = tab }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(state.autoMode ? Theme.green : Theme.muted).frame(width: 8, height: 8)
                Text(state.autoMode ? "AUTO MODE" : "PAUSED").font(Theme.mono(13)).tracking(1.5)
            }
            .foregroundStyle(state.autoMode ? Theme.green : Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Rectangle().stroke(state.autoMode ? Theme.green : Theme.muted, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { state.autoMode.toggle(); state.scan.setAuto(state.autoMode) }

            Caption("FORMAT")
            Picker("", selection: $state.format) {
                ForEach(VinylFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .font(Theme.display(22))

            Rectangle().fill(Theme.line).frame(width: 1, height: 24)
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: 13))
                Text(state.voice.status == .listening ? "LISTENING" : "MIC OFF").font(Theme.mono(13)).tracking(1.5)
            }
            .foregroundStyle(state.voice.status == .listening ? Theme.green : Theme.muted)
            .help(state.voice.lastHeard)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}
