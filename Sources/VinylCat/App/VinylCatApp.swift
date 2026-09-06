import SwiftUI

@main
struct VinylCatApp: App {
    @State private var state = AppState()

    init() {
        // `VinylCat --self-test` runs the built-in checks and exits (no Xcode/XCTest needed).
        if CommandLine.arguments.contains("--self-test") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
        if let code = MainActor.assumeIsolated({ CLI.run(CommandLine.arguments) }) { exit(code) }
        // No window-state restoration: after a crash macOS would otherwise block launch behind a "reopen windows?" alert.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.woodall.vinylcat.savedState"))
        Log.rotate()
    }

    var body: some Scene {
        WindowGroup("VinylCat") {
            RootView()
                .environment(state)
                .frame(minWidth: 1280, minHeight: 820)
                .background(Theme.bg)
                .preferredColorScheme(.dark)
                .task {
                    // First run: the wizard drives permissions and starts services when it finishes.
                    if UserDefaults.standard.bool(forKey: "setupCompleted") { state.startServices() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @AppStorage("setupCompleted") private var setupCompleted = false
    @Environment(\.previewSetupStep) private var previewSetupStep

    var body: some View {
        if !setupCompleted || previewSetupStep != nil {
            SetupWizard()
        } else {
            mainView
        }
    }

    private var mainView: some View {
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
            // Capture mode pill: AUTO ↔ MANUAL (space bar / "capture" always work).
            Button {
                state.autoCapture.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(state.autoCapture ? Theme.green : Theme.amber).frame(width: 8, height: 8)
                    Text(state.autoCapture ? "AUTO CAPTURE" : "MANUAL · SPACE").font(Theme.mono(13)).tracking(1.5)
                }
                .foregroundStyle(state.autoCapture ? Theme.green : Theme.amber)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(Rectangle().stroke(state.autoCapture ? Theme.green : Theme.amber, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to switch between auto-capture and manual (say “capture” or press space)")
            // Space bar = capture, from anywhere in the window.
            Button("") { state.scan.forceCapture() }.keyboardShortcut(.space, modifiers: []).hidden().frame(width: 0, height: 0)

            Caption("FORMAT")
            Picker("", selection: $state.format) {
                ForEach(VinylFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .font(Theme.display(22))

            Rectangle().fill(Theme.line).frame(width: 1, height: 24)
            // Voice button: listening → click to mute; off → click to start (tooltip says why if it can't).
            Button {
                if state.voice.status == .listening { state.voice.stop() } else { Task { await state.voice.retry() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.voice.status == .listening ? "mic.fill" : "mic.slash").font(.system(size: 13))
                    Text(state.voice.status == .listening ? "LISTENING" : (state.voice.problem == nil ? "VOICE OFF" : "VOICE OFF · WHY?")).font(Theme.mono(13)).tracking(1.5)
                }
                .foregroundStyle(state.voice.status == .listening ? Theme.green : (state.voice.problem == nil ? Theme.muted : Theme.amber))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(Rectangle().stroke(state.voice.status == .listening ? Theme.line : (state.voice.problem == nil ? Theme.line : Theme.amber), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.voice.problem ?? (state.voice.status == .listening ? "Listening — click to mute. Last heard: \(state.voice.lastHeard)" : "Click to start listening"))
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}
