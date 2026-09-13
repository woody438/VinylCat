import AppKit
import Foundation

/// The update notice (2026-09-14). The site publishes `release.json` — version, DMG path, one line of
/// notes — and the app reads it at launch and every six hours. When the version there is newer than
/// its own, an amber UPDATE chip appears in the top bar; clicking it shows what's new and opens
/// `vinyl-cat.com/download` (which counts the hit and hands over the DMG). The install itself stays
/// drag-over-the-old-one: without a Developer ID the app cannot safely replace itself the way
/// Sparkle-based apps do. "Skip this version" silences the chip until the next release.
///
/// Nothing is sent — it is a GET for a public JSON file. Settings → ABOUT → "Check for updates" is
/// the user's switch, default on. The bare `.build` binary has no version and never checks.
@MainActor
@Observable
final class UpdateCheck {
    struct Release: Decodable, Equatable, Sendable {
        let version: String
        let file: String
        var notes: String?
    }

    /// `VINYLCAT_RELEASE_URL` points it at a local `npm run dev` of the site (or any JSON) for testing.
    nonisolated static let endpoint = ProcessInfo.processInfo.environment["VINYLCAT_RELEASE_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://vinyl-cat.com/release.json")!
    /// Counts a download on the site, then redirects to the current DMG.
    nonisolated static let downloadURL = URL(string: "https://vinyl-cat.com/download")!
    nonisolated static let interval: Duration = .seconds(6 * 3600)

    private static let enabledKey = "updateCheck"
    private static let skippedKey = "updateSkippedVersion"

    /// The user's switch. Off also clears any notice already showing.
    var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if !enabled { available = nil; status = "Off" } }
    }
    /// The version waved away with "Skip this version": no chip until something newer than it appears.
    var skippedVersion: String = UserDefaults.standard.string(forKey: skippedKey) ?? "" {
        didSet { UserDefaults.standard.set(skippedVersion, forKey: Self.skippedKey) }
    }
    /// The newer release, when there is one the user hasn't skipped.
    var available: Release?
    /// Settings → ABOUT: "Up to date · checked 12:04", "0.2.0 is out …", "Couldn't reach vinyl-cat.com".
    var status = ""
    var checking = false
    /// `--render-ui` forces a release so the chip can be drawn without a network.
    var previewRelease: Release?

    /// The running app's version (`CFBundleShortVersionString`); nil from the bare binary.
    var current: String? { BuildInfo.versionNumber }
    var shown: Release? { previewRelease ?? available }

    /// "0.2.0" is newer than "0.1.9"; components compare as numbers, missing ones count as zero,
    /// anything non-numeric counts as zero too ("1.0-beta" == "1.0").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        var a = parts(candidate), b = parts(current)
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count); b += Array(repeating: 0, count: n - b.count)
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    /// Whether to show the chip: newer than what is running, and not the version the user skipped.
    nonisolated static func shouldOffer(_ release: Release, current: String?, skipped: String) -> Bool {
        guard let current else { return false }
        return isNewer(release.version, than: current) && release.version != skipped
    }

    /// The launch-time loop: check now, then every six hours while the app is open. Cancelled with the view.
    func run() async {
        guard current != nil else { Log.app.debug("update check skipped: no bundle version"); return }
        while !Task.isCancelled {
            if enabled { await check() }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// One read of release.json. Sets `available` and `status`; never throws at the caller.
    func check() async {
        checking = true
        defer { checking = false }
        do {
            let release = try await Self.fetch()
            if Self.shouldOffer(release, current: current, skipped: skippedVersion) {
                available = release
                status = "\(release.version) is out — you have \(current ?? "?")"
            } else {
                available = nil
                status = release.version == skippedVersion && release.version != current ? "\(release.version) skipped" : "Up to date"
            }
            status += " · checked \(Date.now.formatted(date: .omitted, time: .shortened))"
            Log.app.debug("update check: site \(release.version), running \(current ?? "?")")
        } catch {
            status = "Couldn't reach vinyl-cat.com"
            Log.app.debug("update check failed: \(error.localizedDescription)")
        }
    }

    /// GET release.json. Ephemeral session: no cookies, no cache, nothing kept.
    nonisolated static func fetch() async throws -> Release {
        let req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let (data, response) = try await URLSession(configuration: config).data(for: req)
        // A file:// URL (tests) has no HTTP status; anything else must be 2xx.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    func skip() {
        guard let r = available else { return }
        skippedVersion = r.version
        available = nil
        status = "\(r.version) skipped"
    }

    /// Opens the download in the browser. The install page's steps take over from there.
    func download() { NSWorkspace.shared.open(Self.downloadURL) }
}
