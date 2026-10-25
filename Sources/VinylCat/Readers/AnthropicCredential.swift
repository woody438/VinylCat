import Foundation

/// How VinylCat authenticates to the Anthropic API, preferring short-lived credentials over the
/// pasted API key.
///
/// A key in `keys.json` never expires: if it leaks, it works until someone notices and revokes it.
/// The alternatives both hand out tokens that die on their own:
///
///  * **Workload Identity Federation** — a trusted OIDC issuer mints a JWT, Anthropic exchanges it
///    for a short-lived token against a service account, nothing durable sits on disk. This is the
///    right answer for the headless harnesses (`--ocr-eval`, `--import`) if they ever run in CI,
///    where the runner is the identity provider. It cannot be the answer for the Mac app: a
///    personal Mac has no workload identity provider to federate *from*, and a JWT shipped inside
///    the bundle would be a long-lived secret — strictly worse than the key it replaced.
///  * **An OAuth profile** (`ant auth login`) — short-lived access token plus a refresh token,
///    stored by the CLI under `~/.config/anthropic/`. This is the desktop answer.
///
/// Both paths go through the `ant` CLI rather than being hand-rolled here: it already owns the
/// token exchange, the refresh and the profile format, and reimplementing those against an
/// undocumented on-disk layout would be guesswork. No `ant` on the machine means the stored key,
/// which is what every other reader in the app uses.
enum AnthropicCredential {
    enum Auth: Sendable, Equatable {
        /// Pasted key — `x-api-key`.
        case apiKey(String)
        /// Federated or OAuth token — `Authorization: Bearer` plus the oauth beta header.
        case bearer(String)
    }

    enum Source: String, Sendable {
        case federation, oauthProfile, storedKey
        var label: String {
            switch self {
            case .federation: "workload identity federation"
            case .oauthProfile: "OAuth profile (short-lived)"
            case .storedKey: "stored API key"
            }
        }
    }

    struct Resolved: Sendable, Equatable {
        var auth: Auth
        var source: Source
        static func == (a: Resolved, b: Resolved) -> Bool { a.auth == b.auth && a.source == b.source }
    }

    /// The four env vars the SDKs and the CLI treat as "use federation". All of them, or none —
    /// a partial set is a misconfiguration, not a fall-through, so it is worth surfacing.
    static let federationVars = ["ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID",
                                 "ANTHROPIC_SERVICE_ACCOUNT_ID"]

    static var federationConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        let identity = env["ANTHROPIC_IDENTITY_TOKEN_FILE"] ?? env["ANTHROPIC_IDENTITY_TOKEN"]
        return identity?.nilIfEmpty != nil && federationVars.allSatisfy { env[$0]?.nilIfEmpty != nil }
    }

    /// Tokens are short-lived and `print-credentials` refreshes them, so a small cache keeps one
    /// `ant` launch from riding on every photo without holding a token past its life.
    private actor Cache {
        private var value: Resolved?
        private var at = Date.distantPast
        private let ttl: TimeInterval = 240

        func get() -> Resolved? { Date().timeIntervalSince(at) < ttl ? value : nil }
        func put(_ r: Resolved) { value = r; at = Date() }
        func clear() { value = nil; at = .distantPast }
    }

    private static let cache = Cache()

    /// Drop the cached token — call after a 401 so the next read mints a fresh one.
    static func invalidate() async { await cache.clear() }

    /// Best available credential, short-lived first. `nil` means nothing is configured.
    static func resolve() async -> Resolved? {
        if Secrets.disabled { return nil }
        if let hit = await cache.get() { return hit }

        if federationConfigured, let token = await cliToken() {
            let r = Resolved(auth: .bearer(token), source: .federation)
            await cache.put(r)
            return r
        }
        if let token = await cliToken() {
            let r = Resolved(auth: .bearer(token), source: .oauthProfile)
            await cache.put(r)
            return r
        }
        if let key = Keychain.get(.anthropic) {
            // Not cached: Settings can change it between scans, and there is nothing to refresh.
            return Resolved(auth: .apiKey(key), source: .storedKey)
        }
        return nil
    }

    /// `ant auth print-credentials --access-token` — it resolves federation env vars or the active
    /// profile itself and refreshes the token if it is close to expiry. Deliberately not
    /// `ant auth status`: the docs say its exit code is not a health check.
    private static func cliToken() async -> String? {
        guard let exe = cliURL else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = exe
            p.arguments = ["auth", "print-credentials", "--access-token"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                Log.scan.error("ant launch failed: \(error.localizedDescription)")
                return nil
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            // A bare token: no whitespace, and never the whole credentials JSON (the no-flag form
            // prints that, which is the documented foot-gun).
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token, !token.isEmpty, !token.hasPrefix("{"), !token.contains(where: \.isWhitespace) else { return nil }
            return token
        }.value
    }

    /// A GUI app launched from Finder gets a minimal PATH, so the usual install sites are probed
    /// directly. `ANTHROPIC_CLI_PATH` overrides for an unusual install.
    static var cliURL: URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = env["ANTHROPIC_CLI_PATH"]?.nilIfEmpty { candidates.append(override) }
        candidates += ["/opt/homebrew/bin/ant", "/usr/local/bin/ant",
                       NSHomeDirectory() + "/go/bin/ant", "/usr/bin/ant"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// One line for Settings: which credential a scan would use, and what to do about it.
    static func statusLine() -> String {
        if Secrets.disabled { return "Keys disabled for this run (VINYLCAT_NO_KEYCHAIN)." }
        let haveCLI = cliURL != nil
        if federationConfigured {
            return haveCLI ? "Workload identity federation — short-lived tokens, nothing stored here."
                : "Federation env vars are set but the ant CLI is missing; install it or the stored key is used."
        }
        if haveCLI { return "OAuth profile if you have run `ant auth login`, otherwise the stored key." }
        if Keychain.get(.anthropic) != nil { return "Stored API key. It never expires — `brew install anthropics/tap/ant` then `ant auth login` for short-lived tokens instead." }
        return "Nothing configured yet — add an Anthropic key, or install the ant CLI and run `ant auth login` for short-lived tokens."
    }
}
