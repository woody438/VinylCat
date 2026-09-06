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
        HStack(spacing: 20) {
            Text("VINYLCAT").font(Theme.display(26)).tracking(1.5)
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    let active = state.tab == tab
                    Text(tab.rawValue)
                        .font(Theme.mono(13)).tracking(1.5).fixedSize()
                        .foregroundStyle(active ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(active ? Theme.green : .clear).frame(height: 2) }
                        .overlay(alignment: .topTrailing) {
                            if tab == .review && state.reviewCount > 0 { CountBadge(state.reviewCount).offset(x: 4, y: -2) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.tab = tab }
                }
            }
            Spacer()
            // The three top-bar controls share one shape so they read as one set.
            SwitchChip(title: "CAPTURE", state: state.autoCapture ? "AUTO" : "MANUAL", stateWidth: 62,
                       isOn: state.autoCapture, tint: state.autoCapture ? Theme.green : Theme.amber,
                       help: state.autoCapture ? "Auto-capture: fires when the record is held steady. Space bar still forces a shot."
                                               : "Manual: nothing fires on its own — say “capture” or press space.") {
                state.autoCapture.toggle()
            }
            // Space bar = capture, from anywhere in the window.
            Button("") { state.scan.forceCapture() }.keyboardShortcut(.space, modifiers: []).hidden().frame(width: 0, height: 0)

            SwitchChip(title: "VOICE", state: state.voice.status == .listening ? "ON" : "OFF", stateWidth: 34,
                       isOn: state.voice.status == .listening,
                       tint: state.voice.status == .listening ? Theme.green : (state.voice.problem == nil ? Theme.muted : Theme.amber),
                       warning: state.voice.status != .listening && state.voice.problem != nil,
                       help: state.voice.problem ?? (state.voice.status == .listening ? "Listening — click to mute. Last heard: \(state.voice.lastHeard)" : "Click to start listening")) {
                if state.voice.status == .listening { state.voice.stop() } else { Task { await state.voice.retry() } }
            }

            Menu {
                ForEach(VinylFormat.allCases) { f in Button(f.rawValue) { state.format = f } }
            } label: {
                HStack(spacing: 10) {
                    Text("FORMAT").font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
                    Text(state.format.rawValue).font(Theme.mono(12)).tracking(1.5).foregroundStyle(Theme.text)
                        .frame(width: 96, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            .help("What you are cataloguing — narrows the Discogs search")
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}


/// iOS-style count badge: sits on the REVIEW tab without changing its width, so the tab row
/// stays aligned with LIBRARY and SETTINGS.
struct CountBadge: View {
    let count: Int
    init(_ count: Int) { self.count = count }
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Theme.mono(10)).foregroundStyle(Theme.bg)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Theme.red))
    }
}

/// Top-bar toggle: label, switch, and the state it is in. One control shape for capture and voice.
struct SwitchChip: View {
    let title: String
    let state: String
    let stateWidth: CGFloat
    let isOn: Bool
    let tint: Color
    var warning = false
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(Theme.mono(11)).tracking(1.5).foregroundStyle(Theme.muted)
                Capsule().fill(isOn ? tint.opacity(0.3) : Theme.raised)
                    .frame(width: 32, height: 18)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(isOn ? tint : Theme.muted).frame(width: 14, height: 14).padding(2)
                    }
                HStack(spacing: 4) {
                    Text(state).font(Theme.mono(12)).tracking(1.5).foregroundStyle(tint)
                    if warning { Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Theme.amber) }
                }
                .frame(width: stateWidth, alignment: .leading)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .overlay(Rectangle().stroke(isOn ? tint.opacity(0.6) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
