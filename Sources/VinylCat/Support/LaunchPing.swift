import Foundation

/// The take-up counter: one anonymous tick to vinyl-cat.com per launch, so the developer can see
/// whether anyone uses the app. The whole message is `{"event":"launch","version":"0.1.0"}` — the
/// first launch on a Mac sends `install` as well. No identifier, no hardware, no IP kept server-side
/// (site-b/lib/counter.js: three integers in Redis). Best effort: five seconds, then forgotten.
///
/// Sent only from release builds (`scripts/build-app.sh release` stamps `VinylCatChannel`), so a
/// development loop never counts; `VINYLCAT_PING=1` forces it for testing. Settings → ABOUT →
/// "Count launches" is the user's switch, default on.
enum LaunchPing {
    /// `VINYLCAT_PING_URL` points it at a local `npm run dev` of the site for testing.
    static let endpoint = ProcessInfo.processInfo.environment["VINYLCAT_PING_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://vinyl-cat.com/api/ping")!
    private static let enabledKey = "launchPing"
    private static let installSentKey = "launchPingInstallSent"

    /// The user's switch. Default on; the site and the install page say so.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// `release` from a packaged build, `debug` from `build-app.sh debug`, nil from the bare binary.
    static var channel: String? { Bundle.main.infoDictionary?["VinylCatChannel"] as? String }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Whether a launch should be counted, given the build channel, the user's switch and the env override.
    static func shouldSend(channel: String?, enabled: Bool, forced: Bool) -> Bool {
        enabled && (forced || channel == "release")
    }

    /// The request body: nothing but the event name and the app version.
    static func body(event: String, version: String) -> Data {
        // Hand-built so the key order (and the self-test's expected string) is stable.
        Data("{\"event\":\"\(event)\",\"version\":\"\(version)\"}".utf8)
    }

    /// Call once at launch, after the CLI modes have been ruled out.
    static func sendIfEnabled() {
        let forced = ProcessInfo.processInfo.environment["VINYLCAT_PING"] == "1"
        guard shouldSend(channel: channel, enabled: enabled, forced: forced) else {
            Log.app.debug("launch ping skipped (channel \(channel ?? "none"), enabled \(enabled))"); return
        }
        var events = ["launch"]
        if !UserDefaults.standard.bool(forKey: installSentKey) { events.insert("install", at: 0) }
        Task.detached(priority: .utility) {
            for event in events {
                if await send(event: event), event == "install" { UserDefaults.standard.set(true, forKey: installSentKey) }
            }
        }
    }

    /// One POST; true when the site took it. Ephemeral session: no cookies, no cache, nothing kept.
    static func send(event: String) async -> Bool {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body(event: event, version: version)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        do {
            let (_, response) = try await URLSession(configuration: config).data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.app.debug("launch ping \(event) → \(code)")
            return (200..<300).contains(code)
        } catch {
            Log.app.debug("launch ping \(event) failed: \(error.localizedDescription)")
            return false
        }
    }
}
