import AppKit
import Observation
import Security

/*
 * Keeps VinylCat up to date from its GitHub releases (`Updates` says which):
 * looks at launch and every four hours, and installs a newer build when you
 * aren't mid-record, so nothing is interrupted between the shutter and the
 * save. Or by hand, from Settings → UPDATES. With Get preview builds on, a
 * pull request's build counts too; turned off while running a preview, BACK
 * TO MAIN RELEASE installs main's build, though its number is lower.
 *
 * A download is only installed if it is signed with the same certificate as
 * the app that is running ("VinylCat Local Signing", held by CI as a secret —
 * see scripts/sign.sh): its signature must satisfy this app's own designated
 * requirement. An app signed ad hoc has nothing to match, so it never
 * installs anything. The swap happens after the app quits — the old copy
 * moved aside, the new one put in its place, then opened — and a download
 * made here has its quarantine flag stripped, so there is no Open Anyway on
 * an update, only on the very first install. Camera, Microphone and Speech
 * permissions carry over, as it is the same app to macOS.
 *
 * Local builds are not updatable: `scripts/build-app.sh` stamps CFBundleVersion
 * as a date (20261024.1830) and writes no channel, so `enabled` is false and
 * nothing is checked or swapped. Only CI's builds, which carry an integer
 * build number and a channel, take part.
 */
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var available: Updates.Release?
    private(set) var lastChecked: Date?
    /// Main's release, while this is a preview build and previews are off: BACK TO MAIN RELEASE installs it.
    private(set) var mainRelease: Updates.Release?
    /// `--render-ui` forces a release so the chip and popover can be drawn without a network.
    var previewRelease: Updates.Release?
    /// What the top-bar chip shows, if anything.
    var shown: Updates.Release? { previewRelease ?? (enabled ? available : nil) }

    var automatic: Bool = UserDefaults.standard.object(forKey: "installUpdatesAutomatically") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "installUpdatesAutomatically") }
    }

    /// Whether preview builds (a pull request's, before it is merged) count as updates, as main's do.
    /// Off to begin with, unless this copy is itself a preview.
    var previews: Bool = UserDefaults.standard.object(forKey: "getPreviewBuilds") as? Bool
        ?? (Bundle.main.object(forInfoDictionaryKey: "VinylCatUpdateChannel") as? String == "preview") {
        didSet {
            UserDefaults.standard.set(previews, forKey: "getPreviewBuilds")
            if previews != oldValue { check() }
        }
    }

    /// This build's number, as CI stamped it. 0 for a local build, whose CFBundleVersion is a date.
    let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    /// The release this copy came from, or nil in a local build — which is what switches the updater off.
    let channel = Bundle.main.object(forInfoDictionaryKey: "VinylCatUpdateChannel") as? String
    /// The pull request a preview build was built from, where it says.
    let previewPR = Int(Bundle.main.object(forInfoDictionaryKey: "VinylCatPreviewPR") as? String ?? "")

    /// Whether this copy takes part at all: CI's builds do, a local `scripts/build-app.sh` one doesn't.
    var enabled: Bool { channel != nil && build > 0 }

    /// Whether a record is part-scanned or an import is running, when a swap would interrupt.
    /// Set by `AppState`; false here so the updater can be built and tested on its own.
    var isBusy: @MainActor () -> Bool = { false }

    private var timer: Timer?
    private var failedBuild: Int?           // not tried again automatically until a newer one comes
    private var found: [Updates.Release] = []

    static let checkEvery: TimeInterval = 4 * 3600

    func start() {
        guard enabled else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A moment after launch, not during it: the camera and Discogs pull come first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastChecked ?? .distantPast) >= Self.checkEvery { check() }
        guard automatic, !isBusy() else { return }
        if let next = available, next.build != failedBuild, phase == .available, installProblem == nil {
            install()
        }
    }

    /// Why the app can't replace itself where it is, or nil when it can.
    var installProblem: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "Move VinylCat to the Applications folder first."
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else {
            return "VinylCat can't replace itself in \(app.deletingLastPathComponent().path): download the new build from the release page."
        }
        return nil
    }

    /// The release page for this app's channel.
    var releasePage: URL {
        URL(string: "https://github.com/\(Updates.repository)/releases/tag/\(channel ?? "latest")")!
    }

    // MARK: Checking

    func check() {
        guard enabled, phase != .checking, phase != .downloading, phase != .installing else { return }
        phase = .checking
        let previews = self.previews
        Task {
            var found: [Updates.Release] = []
            for c in Updates.channels(previews: previews) {
                if let release = await fetch(c) { found.append(release) }
            }
            lastChecked = Date()
            available = Updates.newest(found, after: build)
            if found.isEmpty {
                phase = .failed("Couldn't reach GitHub")
            } else {
                phase = available == nil ? .upToDate : .available
            }
            if !found.isEmpty { self.found = found }      // GitHub out of reach: keep what it last said
            mainRelease = Updates.backToMain(self.found, running: build, channel: channel ?? "latest", previews: previews)
            Log.update.info("checked: build \(build), found \(found.map(\.build)), available \(available?.build ?? 0)")
            if previews != self.previews { check() }      // switched while it looked: again, for what's followed now
        }
    }

    /// Installs main's release over this preview build, though its number is lower.
    func backToMain() {
        guard let release = mainRelease else { return }
        available = release
        install()
    }

    private func fetch(_ channel: String) async -> Updates.Release? {
        var request = URLRequest(url: Updates.url(channel, "VinylCat.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let got = try? await URLSession.shared.data(for: request),
              (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Updates.decode(got.0)
    }

    // MARK: Installing

    enum UpdateError: LocalizedError {
        case download, unzip, notTheApp, adHoc, signature(OSStatus)
        var errorDescription: String? {
            switch self {
            case .download: return "The download didn't finish"
            case .unzip: return "The download wouldn't unzip"
            case .notTheApp: return "The download isn't the build expected"
            case .adHoc: return "This copy isn't signed with the project's certificate, so it can't check an update: download the new build from the release page"
            case .signature(let status): return "The download isn't signed with the project's certificate (\(status)), so it wasn't installed"
            }
        }
    }

    /// Downloads the newer build, checks it, and swaps it in: the app quits and reopens.
    func install() {
        guard let release = available, phase == .available || phase == .upToDate || isFailed else { return }
        if let problem = installProblem {
            phase = .failed(problem)
            return
        }
        let target = Bundle.main.bundleURL
        phase = .downloading
        Task {
            do {
                // Beside the app, on the same disk, so the swap is a rename rather than a copy.
                let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
                let zip = dir.appendingPathComponent("VinylCat.zip")
                var request = URLRequest(url: Updates.url(release.channel, "VinylCat.zip"))
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (file, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
                try FileManager.default.moveItem(at: file, to: zip)
                guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else { throw UpdateError.unzip }
                try? FileManager.default.removeItem(at: zip)
                let app = dir.appendingPathComponent(target.lastPathComponent)
                _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                try Self.verify(app, build: release.build)
                phase = .installing
                Log.update.info("installing build \(release.build) over \(build)")
                try relaunch(replacing: target, with: app)
            } catch {
                failedBuild = release.build
                phase = .failed(error.localizedDescription)
                Log.update.error("install failed: \(error.localizedDescription)")
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// The download must be this app, the build expected, and signed with the
    /// certificate this one is: it must satisfy this app's designated requirement.
    private static func verify(_ app: URL, build: Int) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(info["CFBundleVersion"] as? String ?? "") == build else { throw UpdateError.notTheApp }

        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.adHoc
        }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        // Signed ad hoc, the requirement is this build's own hash, which no other build can ever meet.
        guard let text, (text as String).contains("certificate") else { throw UpdateError.adHoc }

        var download: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &download)
        guard created == errSecSuccess, let download else { throw UpdateError.signature(created) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
                               | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidityWithErrors(download, flags, requirement, nil)
        guard status == errSecSuccess else { throw UpdateError.signature(status) }
    }

    /// Quits, and leaves a shell to swap the apps once it has, then open the new one.
    private func relaunch(replacing target: URL, with app: URL) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        if /bin/mv "$2" "$2.old"; then
          if /bin/mv "$3" "$2"; then /bin/rm -rf "$2.old"; else /bin/mv "$2.old" "$2"; fi
        fi
        /usr/bin/open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "vinylcat-update", String(getpid()), target.path, app.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { done in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { done.resume(returning: -1) }
        }
    }

    /// One line for Settings: what is happening, or what is there.
    var statusLine: String {
        guard enabled else { return "Off in a local build — CI's builds update themselves" }
        switch phase {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date" + (lastChecked.map { " · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .available: return "Build \(available?.build ?? 0) is ready" + (automatic ? " — installs when you're between records" : "")
        case .downloading: return "Downloading build \(available?.build ?? 0)…"
        case .installing: return "Installing; VinylCat will reopen…"
        case .failed(let why): return why
        }
    }
}
