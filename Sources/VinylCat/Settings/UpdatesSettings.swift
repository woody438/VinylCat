import SwiftUI

/// Settings → UPDATES: which build this is, what's waiting, and the two switches —
/// install on its own, and follow the preview stream. Its own file so the card can
/// grow without touching the rest of Settings (see `Updater` for what it drives).
struct UpdatesSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var updater = state.updater
        VStack(alignment: .leading, spacing: 6) {
            UpdateRow("This build") {
                // Outside a bundle there is no version to read, so ABOUT's wording stands in.
                Text(updater.enabled ? "\(updater.version) · build \(updater.build)" : BuildInfo.version)
                    .foregroundStyle(Theme.secondary)
            }
            if updater.channel == "preview" {
                UpdateRow("Stream") {
                    Text(updater.previewPR.map { "PREVIEW · PR #\($0)" } ?? "PREVIEW")
                        .foregroundStyle(Theme.amber)
                }
            }
            UpdateRow("Updates") {
                HStack(spacing: 10) {
                    Text(updater.statusLine)
                        .foregroundStyle(Theme.secondary).font(Theme.mono(11))
                        .lineLimit(2).multilineTextAlignment(.trailing)
                    if updater.enabled {
                        switch updater.phase {
                        case .available, .failed where updater.available != nil:
                            Button("INSTALL NOW") { updater.install() }.fixedSize()
                        case .downloading, .installing:
                            EmptyView()
                        default:
                            Button("CHECK NOW") { updater.check() }.fixedSize()
                        }
                    }
                }
            }
            if updater.enabled {
                UpdateRow("Install updates on its own") {
                    Toggle("", isOn: $updater.automatic).labelsHidden().toggleStyle(.switch)
                }
                UpdateRow("Get preview builds") {
                    Toggle("", isOn: $updater.previews).labelsHidden().toggleStyle(.switch)
                }
                // Previews off while running one: main's build is older by number, so going back is by hand.
                if let main = updater.mainRelease {
                    UpdateRow("Main's build is \(main.build)") {
                        Button("BACK TO MAIN RELEASE") { updater.backToMain() }
                            .fixedSize()
                            .disabled(updater.phase == .downloading || updater.phase == .installing)
                    }
                }
            }
            if let problem = updater.installProblem, updater.enabled {
                Text(problem)
                    .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Text(note(updater))
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    private func note(_ updater: Updater) -> String {
        guard updater.enabled else {
            return "This copy was built on the Mac, so it has no build number to compare and never updates itself — "
                 + "rebuild it with scripts/build-app.sh. The builds published from GitHub check every four hours and "
                 + "install a newer one between records."
        }
        if updater.channel == "preview" {
            let pr = updater.previewPR.map { "pull request #\($0)" } ?? "a pull request"
            return "This copy is a preview, built from \(pr) to try before it's merged. With Get preview builds on it "
                 + "takes newer previews and main's releases. Off, it waits for main's next build — or BACK TO MAIN "
                 + "RELEASE goes back now. Only a build signed with the project's certificate is ever installed."
        }
        return "VinylCat looks for a new build every four hours and installs it when you're between records — never "
             + "mid-scan or mid-import. It closes and reopens in a second or two, keeping your camera, microphone and "
             + "speech permissions, your catalogue and your photos. Get preview builds takes a pull request's build "
             + "too, to try a change early. Only a build signed with the project's certificate is ever installed."
    }
}

/// The same label-left, control-right line Settings uses elsewhere; `Row` there is private to its file.
private struct UpdateRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.mono(13)).foregroundStyle(Theme.muted)
            Spacer()
            content.font(Theme.mono(13))
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
